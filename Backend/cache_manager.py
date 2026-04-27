# server/cache_manager.py
"""
Cache manager for API responses (Weather, AQI, etc.)
Reduces redundant API calls and costs
"""
raise RuntimeError(
    "SQL CacheManager is deprecated. Use RedisCache from server.redis_client"
)

import json
import logging
from datetime import datetime, timedelta
from typing import Optional, Dict, Any
from sqlalchemy import text

from server.geofencing.database import get_geofence_db, APICache

logger = logging.getLogger(__name__)

class CacheManager:
    """Manages caching of external API responses"""
    
    # Cache durations (in minutes)
    CACHE_DURATIONS = {
        'weather': 60,      # 1 hour
        'aqi': 60,          # 1 hour
        'altitude': 1440,   # 24 hours (static data)
        'geocode': 10080    # 7 days (static data)
    }
    
    def _generate_cache_key(self, api_type: str, lat: float, lon: float) -> str:
        """Generate cache key from API type and coordinates"""
        # Round to 2 decimal places for better cache hits
        lat_round = round(lat, 2)
        lon_round = round(lon, 2)
        return f"{api_type}_{lat_round}_{lon_round}"
    
    def get(self, api_type: str, lat: float, lon: float) -> Optional[Dict[str, Any]]:
        """
        Get cached API response
        
        Args:
            api_type: Type of API (weather, aqi, altitude, geocode)
            lat: Latitude
            lon: Longitude
            
        Returns:
            Cached data or None if not found/expired
        """
        try:
            cache_key = self._generate_cache_key(api_type, lat, lon)
            
            with get_geofence_db() as db:
                result = db.execute(
                    text("""
                        SELECT cache_value, expires_at 
                        FROM api_cache 
                        WHERE cache_key = :key
                    """),
                    {'key': cache_key}
                ).fetchone()
                
                if result:
                    cache_value, expires_at = result
                    
                    # Check if expired
                    if expires_at > datetime.utcnow():
                        logger.info(f"✅ Cache HIT: {cache_key}")
                        return cache_value
                    else:
                        # Delete expired entry
                        db.execute(
                            text("DELETE FROM api_cache WHERE cache_key = :key"),
                            {'key': cache_key}
                        )
                        db.commit()
                        logger.info(f"🗑️  Cache EXPIRED: {cache_key}")
                
                logger.info(f"❌ Cache MISS: {cache_key}")
                return None
                
        except Exception as e:
            logger.error(f"Cache get failed: {e}")
            return None
    
    def set(self, api_type: str, lat: float, lon: float, data: Dict[str, Any]) -> bool:
        """
        Cache API response
        
        Args:
            api_type: Type of API
            lat: Latitude
            lon: Longitude
            data: Data to cache
            
        Returns:
            bool: Success status
        """
        try:
            cache_key = self._generate_cache_key(api_type, lat, lon)
            duration_minutes = self.CACHE_DURATIONS.get(api_type, 60)
            expires_at = datetime.utcnow() + timedelta(minutes=duration_minutes)
            
            with get_geofence_db() as db:
                # Upsert (insert or update)
                db.execute(
                    text("""
                        INSERT INTO api_cache (cache_key, cache_value, expires_at, created_at)
                        VALUES (:key, :value, :expires, :created)
                        ON CONFLICT (cache_key) DO UPDATE SET
                            cache_value = EXCLUDED.cache_value,
                            expires_at = EXCLUDED.expires_at,
                            created_at = EXCLUDED.created_at
                    """),
                    {
                        'key': cache_key,
                        'value': json.dumps(data),
                        'expires': expires_at,
                        'created': datetime.utcnow()
                    }
                )
                db.commit()
                logger.info(f"💾 Cache SET: {cache_key} (expires in {duration_minutes}min)")
                return True
                
        except Exception as e:
            logger.error(f"Cache set failed: {e}")
            return False
    
    def clear_expired(self) -> int:
        """
        Clear all expired cache entries
        
        Returns:
            int: Number of entries deleted
        """
        try:
            with get_geofence_db() as db:
                result = db.execute(
                    text("""
                        DELETE FROM api_cache 
                        WHERE expires_at < :now
                        RETURNING cache_key
                    """),
                    {'now': datetime.utcnow()}
                )
                count = len(result.fetchall())
                db.commit()
                
                if count > 0:
                    logger.info(f"🗑️  Cleared {count} expired cache entries")
                
                return count
                
        except Exception as e:
            logger.error(f"Cache clear failed: {e}")
            return 0

# Global instance
cache_manager = CacheManager()