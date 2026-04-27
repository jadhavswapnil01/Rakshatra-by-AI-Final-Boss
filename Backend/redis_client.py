# Backend/server/redis_client.py
"""
Redis Client for Caching and Real-time Pub/Sub

PERFORMANCE GAIN:
- SQL Cache Read: ~50-100ms
- Redis Cache Read: <1ms

FEATURES:
1. Caching: Weather, AQI, geofence data
2. Pub/Sub: Real-time dashboard updates
3. Session Storage: (optional) JWT tokens
"""

import os
import json
import logging
from typing import Optional, Any, AsyncGenerator
from datetime import timedelta

import redis.asyncio as aioredis
from redis.asyncio import ConnectionPool, Redis

logger = logging.getLogger(__name__)

# ============================================
# Redis Configuration
# ============================================

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# Create connection pool (reused across requests)
redis_pool = ConnectionPool.from_url(
    REDIS_URL,
    max_connections=50,
    decode_responses=True,  # Automatically decode bytes to strings
)

# ============================================
# Redis Client Factory
# ============================================

async def get_redis() -> AsyncGenerator[Redis, None]:
    """
    FastAPI dependency for Redis client.
    
    Usage:
    ```python
    @router.get("/weather")
    async def get_weather(redis: Redis = Depends(get_redis)):
        cached = await redis.get("weather:pune")
        if cached:
            return json.loads(cached)
        # ... fetch from API
    ```
    """
    client = Redis(connection_pool=redis_pool)
    try:
        yield client
    finally:
        await client.aclose()


def get_redis_sync() -> Redis:
    """Get Redis client for synchronous code (Celery tasks)"""
    return Redis(connection_pool=redis_pool)


# ============================================
# Cache Manager Class
# ============================================

class RedisCache:
    """
    High-level caching interface replacing your SQL-based cache.
    
    This replaces server/cache_manager.py which writes to PostgreSQL.
    """
    
    def __init__(self):
        self.pool = redis_pool
        self.default_ttl = 3600  # 1 hour default
    
    async def _get_client(self) -> Redis:
        return Redis(connection_pool=self.pool)
    
    async def get(self, key: str) -> Optional[Any]:
        """Get cached value"""
        client = await self._get_client()
        try:
            value = await client.get(key)
            if value:
                return json.loads(value)
            return None
        except Exception as e:
            logger.error(f"Redis GET error: {e}")
            return None
        finally:
            await client.aclose()
    
    async def set(self, key: str, value: Any, ttl: int = None) -> bool:
        """Set cached value with TTL"""
        client = await self._get_client()
        try:
            ttl = ttl or self.default_ttl
            await client.setex(key, ttl, json.dumps(value))
            return True
        except Exception as e:
            logger.error(f"Redis SET error: {e}")
            return False
        finally:
            await client.aclose()
    
    async def delete(self, key: str) -> bool:
        """Delete cached value"""
        client = await self._get_client()
        try:
            await client.delete(key)
            return True
        except Exception as e:
            logger.error(f"Redis DELETE error: {e}")
            return False
        finally:
            await client.aclose()
    
    async def exists(self, key: str) -> bool:
        """Check if key exists"""
        client = await self._get_client()
        try:
            return await client.exists(key) > 0
        finally:
            await client.aclose()
    
    async def get_or_set(self, key: str, factory_func, ttl: int = None) -> Any:
        """
        Get from cache or compute and cache.
        
        Usage:
        ```python
        weather = await cache.get_or_set(
            f"weather:{city}",
            lambda: fetch_weather_from_api(city),
            ttl=1800  # 30 minutes
        )
        ```
        """
        cached = await self.get(key)
        if cached is not None:
            logger.debug(f"Cache HIT: {key}")
            return cached
        
        logger.debug(f"Cache MISS: {key}")
        
        # Call factory function (can be async or sync)
        import asyncio
        if asyncio.iscoroutinefunction(factory_func):
            value = await factory_func()
        else:
            value = factory_func()
        
        # Cache the result
        await self.set(key, value, ttl)
        return value
    
    # ==========================================
    # Specific Cache Methods (Replacing your SQL cache)
    # ==========================================
    
    async def cache_weather(self, lat: float, lng: float, data: dict, ttl: int = 1800):
        """Cache weather data (30 min default)"""
        key = f"weather:{lat:.2f}:{lng:.2f}"
        await self.set(key, data, ttl)
    
    async def get_weather(self, lat: float, lng: float) -> Optional[dict]:
        """Get cached weather"""
        key = f"weather:{lat:.2f}:{lng:.2f}"
        return await self.get(key)
    
    async def cache_aqi(self, lat: float, lng: float, data: dict, ttl: int = 1800):
        """Cache AQI data (30 min default)"""
        key = f"aqi:{lat:.2f}:{lng:.2f}"
        await self.set(key, data, ttl)
    
    async def get_aqi(self, lat: float, lng: float) -> Optional[dict]:
        """Get cached AQI"""
        key = f"aqi:{lat:.2f}:{lng:.2f}"
        return await self.get(key)
    
    async def cache_geofences(self, city: str, data: list, ttl: int = 300):
        """Cache geofences for a city (5 min default)"""
        key = f"geofences:{city.lower()}"
        await self.set(key, data, ttl)
    
    async def get_geofences(self, city: str) -> Optional[list]:
        """Get cached geofences"""
        key = f"geofences:{city.lower()}"
        return await self.get(key)
    
    async def invalidate_geofences(self, city: str):
        """Invalidate geofence cache when new alert created"""
        key = f"geofences:{city.lower()}"
        await self.delete(key)
        
    async def cache_active_geofences(self, data: list, ttl: int = 300):
        await self.set("geofences:active", data, ttl)

    async def get_active_geofences(self) -> Optional[list]:
        return await self.get("geofences:active")

    async def invalidate_active_geofences(self):
        await self.delete("geofences:active")
    
    async def clear_expired(self):
        """
        Clear expired cache entries.
        Redis handles TTL automatically, but this can be used
        for manual cleanup of pattern-matched keys.
        """
        client = await self._get_client()
        try:
            # Redis automatically expires keys with TTL
            # This method can be used for pattern-based cleanup
            logger.info("Cache cleanup triggered - Redis handles TTL automatically")
            
            # Optional: Scan and log cache stats
            cursor = 0
            total_keys = 0
            while True:
                cursor, keys = await client.scan(cursor, count=100)
                total_keys += len(keys)
                if cursor == 0:
                    break
            
            logger.info(f"Cache status: {total_keys} active keys")
            return {"status": "ok", "active_keys": total_keys}
        except Exception as e:
            logger.error(f"Cache cleanup error: {e}")
            return {"status": "error", "error": str(e)}
        finally:
            await client.aclose()


# Global cache instance
redis_cache = RedisCache()


# ============================================
# Pub/Sub for Real-time Updates
# ============================================

class RedisPubSub:
    """
    Redis Pub/Sub for real-time dashboard updates.
    
    CHANNELS:
    - dashboard_alerts: New alerts created
    - tourist_updates: Tourist location updates
    - sos_events: SOS triggered
    - group_events: Group membership changes
    """
    
    CHANNEL_DASHBOARD = "dashboard_alerts"
    CHANNEL_TOURIST = "tourist_updates"
    CHANNEL_SOS = "sos_events"
    CHANNEL_GROUP = "group_events"
    
    def __init__(self):
        self.pool = redis_pool
    
    async def _get_client(self) -> Redis:
        return Redis(connection_pool=self.pool)
    
    async def publish(self, channel: str, message: dict) -> int:
        """
        Publish message to channel.
        
        Usage (in alerts.py when creating alert):
        ```python
        await redis_pubsub.publish(
            RedisPubSub.CHANNEL_DASHBOARD,
            {
                "event": "new_alert",
                "alert_id": alert.id,
                "tourist_id": alert.tourist_id,
                "type": alert.alert_type.value,
                "severity": alert.severity.value
            }
        )
        ```
        """
        client = await self._get_client()
        try:
            subscribers = await client.publish(channel, json.dumps(message))
            logger.info(f"Published to {channel}: {subscribers} subscribers")
            return subscribers
        except Exception as e:
            logger.error(f"Redis PUBLISH error: {e}")
            return 0
        finally:
            await client.aclose()
    
    async def subscribe(self, channel: str):
        """
        Subscribe to channel (used by SSE endpoint).
        
        Returns an async generator of messages.
        """
        client = await self._get_client()
        pubsub = client.pubsub()
        await pubsub.subscribe(channel)
        
        try:
            async for message in pubsub.listen():
                if message["type"] == "message":
                    yield json.loads(message["data"])
        finally:
            await pubsub.unsubscribe(channel)
            await pubsub.aclose()
            await client.aclose()
    
    # ==========================================
    # Convenience Methods
    # ==========================================
    
    async def publish_new_alert(self, alert_data: dict):
        """Publish new alert event"""
        await self.publish(self.CHANNEL_DASHBOARD, {
            "event": "new_alert",
            "timestamp": alert_data.get("created_at"),
            "data": alert_data
        })
    
    async def publish_alert_update(self, alert_id: int, status: str):
        """Publish alert status update"""
        await self.publish(self.CHANNEL_DASHBOARD, {
            "event": "alert_updated",
            "alert_id": alert_id,
            "status": status
        })
    
    async def publish_sos(self, tourist_id: str, location: dict, alert_id: int):
        """Publish SOS event"""
        await self.publish(self.CHANNEL_SOS, {
            "event": "sos_triggered",
            "tourist_id": tourist_id,
            "alert_id": alert_id,
            "location": location
        })
    
    async def publish_location_update(self, tourist_id: str, location: dict):
        """Publish tourist location update"""
        await self.publish(self.CHANNEL_TOURIST, {
            "event": "location_update",
            "tourist_id": tourist_id,
            "location": location
        })


# Global pubsub instance
redis_pubsub = RedisPubSub()


# ============================================
# Health Check
# ============================================

async def check_redis_connection() -> bool:
    """Check if Redis is accessible"""
    try:
        client = Redis(connection_pool=redis_pool)
        await client.ping()
        await client.aclose()
        return True
    except Exception as e:
        logger.error(f"Redis health check failed: {e}")
        return False


# ============================================
# Rate Limiting (Bonus Feature)
# ============================================

class RateLimiter:
    """
    Redis-based rate limiting.
    
    Usage:
    ```python
    limiter = RateLimiter()
    
    @router.post("/otp/send")
    async def send_otp(phone: str):
        allowed = await limiter.is_allowed(f"otp:{phone}", limit=5, window=3600)
        if not allowed:
            raise HTTPException(429, "Too many OTP requests")
        # ... send OTP
    ```
    """
    
    def __init__(self):
        self.pool = redis_pool
    
    async def is_allowed(self, key: str, limit: int, window: int) -> bool:
        """
        Check if action is allowed within rate limit.
        
        Args:
            key: Unique identifier (e.g., "otp:+91xxxxxxxxxx")
            limit: Max requests allowed
            window: Time window in seconds
        
        Returns:
            True if allowed, False if rate limited
        """
        client = Redis(connection_pool=self.pool)
        try:
            current = await client.get(key)
            
            if current is None:
                await client.setex(key, window, 1)
                return True
            
            if int(current) >= limit:
                return False
            
            await client.incr(key)
            return True
            
        except Exception as e:
            logger.error(f"Rate limit check failed: {e}")
            return True  # Allow on error
        finally:
            await client.aclose()


# Global rate limiter
rate_limiter = RateLimiter()
