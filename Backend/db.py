# server/db.py
import os
import logging
from typing import Optional
from sqlalchemy import create_engine, text, Column, String, BigInteger, Text, Integer, Float, Boolean, Enum, JSON, Index, ForeignKey, DECIMAL, UniqueConstraint
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session, relationship
from sqlalchemy.dialects.mysql import LONGTEXT
from contextlib import contextmanager
import enum

logger = logging.getLogger(__name__)
raw_url = os.getenv("MYSQL_URI", "mysql+pymysql://root:root123@127.0.0.1/dtid_db")
# Database configuration
DATABASE_URL = raw_url.replace("mysql+aiomysql", "mysql+pymysql")

engine = create_engine(
    DATABASE_URL,
    echo=False,
    pool_pre_ping=True,
    pool_recycle=3600,
    future=True
)

SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
Base = declarative_base()

# Enums for database fields
class TouristStatus(enum.Enum):
    ACTIVE = "ACTIVE"
    SUSPENDED = "SUSPENDED" 
    REVOKED = "REVOKED"

class OTPPurpose(enum.Enum):
    REGISTRATION = "REGISTRATION"
    LOGIN = "LOGIN"
    PASSWORD_RESET = "PASSWORD_RESET"

class RiskLevel(enum.Enum):
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"
    RESTRICTED = "RESTRICTED"

class AlertType(enum.Enum):
    GEO = "GEO"
    ANOMALY = "ANOMALY"
    SOS = "SOS"
    MANUAL = "MANUAL"
    LOW_BATTERY = "LOW_BATTERY"
    OFFLINE = "OFFLINE"
    INACTIVITY = "INACTIVITY"
    FALL_DETECTED = "FALL_DETECTED"
    DEVIATION = "DEVIATION"

class AlertSeverity(enum.Enum):
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"
    CRITICAL = "CRITICAL"

class AlertStatus(enum.Enum):
    ACTIVE = "ACTIVE"
    ACKNOWLEDGED = "ACKNOWLEDGED"
    RESOLVED = "RESOLVED"
    FALSE_POSITIVE = "FALSE_POSITIVE"
    AWAITING_RESPONSE = "AWAITING_RESPONSE"

class AuthorityRole(enum.Enum):
    POLICE = "POLICE"
    FOREST = "FOREST"
    MEDICAL = "MEDICAL"
    RESCUE = "RESCUE"
    ADMIN = "ADMIN"

class AuthorityStatus(enum.Enum):
    ACTIVE = "ACTIVE"
    SUSPENDED = "SUSPENDED"
    REVOKED = "REVOKED"

class SampleSource(enum.Enum):
    GPS = "GPS"
    FUSED = "FUSED"
    SIGNIFICANT_CHANGE = "SIGNIFICANT_CHANGE"
    MANUAL = "MANUAL"

class GeometryType(enum.Enum):
    POLYGON = "POLYGON"
    CIRCLE = "CIRCLE"

class BucketType(enum.Enum):
    HOURLY = "HOURLY"
    DAILY = "DAILY"
    WEEKLY = "WEEKLY"

class GroupRole(enum.Enum):
    ADMIN = "ADMIN"
    MEMBER = "MEMBER"

class GroupVisibility(enum.Enum):
    PRIVATE = "PRIVATE"
    INVITE_ONLY = "INVITE_ONLY"

class SessionStatus(enum.Enum):
    ACTIVE = "ACTIVE"
    ENDED = "ENDED"

class MediaType(enum.Enum):
    AUDIO = "AUDIO"
    VIDEO = "VIDEO"
    IMAGE = "IMAGE"

class EntityType(enum.Enum):
    HOTEL = "HOTEL"
    TAXI_OPERATOR = "TAXI_OPERATOR"
    GUIDE = "GUIDE"
    RESTAURANT = "RESTAURANT"
    SHOP = "SHOP"

class VerificationStatus(enum.Enum):
    PENDING = "PENDING"
    VERIFIED = "VERIFIED"
    REJECTED = "REJECTED"

class VerificationTier(enum.Enum):
    BRONZE = "BRONZE"
    SILVER = "SILVER"
    GOLD = "GOLD"

class AnomalyType(enum.Enum):
    INACTIVITY = "INACTIVITY"
    FALL_DETECTED = "FALL_DETECTED"
    GEOFENCE_STAY = "GEOFENCE_STAY"
    ROUTE_DEVIATION = "ROUTE_DEVIATION"

class CallResult(enum.Enum):
    CONNECTED = "CONNECTED"
    NO_ANSWER = "NO_ANSWER"
    BUSY = "BUSY"
    FAILED = "FAILED"

# Database Models
class Tourist(Base):
    __tablename__ = "tourists"
    
    id = Column(String(64), primary_key=True, index=True, comment="DTID token string")
    ble_hash = Column(String(8), nullable=False, index=True, comment="Short hash for BLE broadcast (last 6 chars of token_id)")
    mobile_hash = Column(String(64), nullable=False, unique=True, comment="SHA-256 hash of mobile number with pepper")
    encrypted_profile = Column(LONGTEXT, nullable=False, comment="AES-GCM JSON blob with PII data")
    profile_dek_wrapped = Column(LONGTEXT, nullable=False, comment="Wrapped DEK for decrypting profile")
    profile_hash = Column(String(64), nullable=False, comment="SHA-256 of encrypted_profile")
    pointer = Column(String(128), nullable=False, comment="Chain pointer like local:DTID-xxx")
    issuer = Column(String(128), default='local-issuer')
    valid_from = Column(BigInteger, nullable=False)
    valid_till = Column(BigInteger, nullable=False)
    consent = Column(JSON, default=lambda: {})
    status = Column(Enum(TouristStatus), default=TouristStatus.ACTIVE)
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=True)
    last_login = Column(BigInteger, nullable=True)
    fcm_token = Column(String(255), nullable=True, comment="Firebase Cloud Messaging token for push notifications")
    
    # --- ADD THESE MISSING COLUMNS ---
    profile_photo_ipfs_cid = Column(String(255), nullable=True, comment="IPFS CID of profile photo")
    face_encoding_hash = Column(String(64), nullable=True, index=True, comment="Hash of face encoding for privacy")
    face_encoding_encrypted = Column(Text, nullable=True, comment="Encrypted face encoding data")
    # ---------------------------------
    
    # Relationships
    location_samples = relationship("LocationSample", back_populates="tourist", cascade="all, delete-orphan")
    safety_scores = relationship("SafetyScore", back_populates="tourist", cascade="all, delete-orphan")
    alerts = relationship("Alert", back_populates="tourist", cascade="all, delete-orphan")
    emergency_contacts = relationship("EmergencyContact", back_populates="tourist", cascade="all, delete-orphan")
    access_logs = relationship("AccessLog", back_populates="token", cascade="all, delete-orphan")
    owned_groups = relationship("TouristGroup", back_populates="owner", cascade="all, delete-orphan")
    group_memberships = relationship("GroupMember", back_populates="tourist", cascade="all, delete-orphan")
    live_sessions = relationship("LiveShareSession", back_populates="tourist", cascade="all, delete-orphan")
    entity_ratings = relationship("EntityRating", back_populates="tourist", cascade="all, delete-orphan")
    
    __table_args__ = (
        Index('idx_mobile_hash', 'mobile_hash'),
        Index('idx_valid_period', 'valid_from', 'valid_till'),
        Index('idx_created_at', 'created_at'),
        Index('idx_status', 'status'),
    )

class OTPVerification(Base):
    __tablename__ = "otp_verifications"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    mobile_number = Column(String(20), nullable=False)
    otp_hash = Column(String(64), nullable=False, comment="SHA-256 hash of OTP")
    purpose = Column(Enum(OTPPurpose), nullable=False)
    verified = Column(Boolean, default=False)
    attempts = Column(Integer, default=0)
    created_at = Column(BigInteger, nullable=False)
    expires_at = Column(BigInteger, nullable=False)
    verified_at = Column(BigInteger, nullable=True)
    
    __table_args__ = (
        Index('idx_mobile_purpose', 'mobile_number', 'purpose'),
        Index('idx_expires_at', 'expires_at'),
    )

class TouristGroup(Base):
    __tablename__ = "tourist_groups"
    
    id = Column(String(64), primary_key=True, index=True)
    name = Column(String(255), nullable=False)
    owner_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    settings = Column(JSON, comment='{"proximity_alert_meters": 50, "auto_share_sos": true}')
    visibility = Column(Enum(GroupVisibility), default=GroupVisibility.INVITE_ONLY)
    created_at = Column(BigInteger, nullable=False)
    expires_at = Column(BigInteger, nullable=True)
    
    # Relationships
    owner = relationship("Tourist", back_populates="owned_groups")
    members = relationship("GroupMember", back_populates="group", cascade="all, delete-orphan")
    invites = relationship("GroupInvite", back_populates="group", cascade="all, delete-orphan")
    
    __table_args__ = (
        Index('idx_owner', 'owner_id'),
    )

class GroupMember(Base):
    __tablename__ = "group_members"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    group_id = Column(String(64), ForeignKey('tourist_groups.id'), nullable=False)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    role = Column(Enum(GroupRole), default=GroupRole.MEMBER)
    joined_at = Column(BigInteger, nullable=False)
    
    # Relationships
    group = relationship("TouristGroup", back_populates="members")
    tourist = relationship("Tourist", back_populates="group_memberships")
    
    __table_args__ = (
        UniqueConstraint('group_id', 'tourist_id', name='unique_group_member'),
        Index('idx_tourist_groups', 'tourist_id'),
    )

class GroupInvite(Base):
    __tablename__ = "group_invites"
    
    id = Column(String(64), primary_key=True, index=True)
    group_id = Column(String(64), ForeignKey('tourist_groups.id'), nullable=False)
    invite_token = Column(String(32), nullable=False, unique=True)
    issued_by_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    created_at = Column(BigInteger, nullable=False)
    expires_at = Column(BigInteger, nullable=False)
    used_at = Column(BigInteger, nullable=True)
    used_by_id = Column(String(64), ForeignKey('tourists.id'), nullable=True)
    
    # Relationships
    group = relationship("TouristGroup", back_populates="invites")
    issuer = relationship("Tourist", foreign_keys=[issued_by_id])
    user = relationship("Tourist", foreign_keys=[used_by_id])
    
    __table_args__ = (
        Index('idx_token', 'invite_token'),
        Index('idx_expires', 'expires_at'),
    )

class LiveShareSession(Base):
    __tablename__ = "live_share_sessions"
    
    id = Column(String(64), primary_key=True, index=True)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    sampling_rate_seconds = Column(Integer, default=5)
    shared_with = Column(JSON, nullable=False, comment='{"groups": ["grp-uuid-123"], "authorities": ["POLICE"]}')
    status = Column(Enum(SessionStatus), default=SessionStatus.ACTIVE)
    start_ts = Column(BigInteger, nullable=False)
    end_ts = Column(BigInteger, nullable=True)
    
    # Relationships
    tourist = relationship("Tourist", back_populates="live_sessions")
    alerts = relationship("Alert", back_populates="live_session")
    
    __table_args__ = (
        Index('idx_tourist_active', 'tourist_id', 'status'),
        Index('idx_status_start', 'status', 'start_ts'),
    )

class LocationSample(Base):
    __tablename__ = "location_samples"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    live_session_id = Column(String(64), nullable=True, comment="Identifier for a live tracking session")
    timestamp = Column(BigInteger, nullable=False)
    lat = Column(DECIMAL(10, 7), nullable=False)
    lon = Column(DECIMAL(10, 7), nullable=False)
    accuracy = Column(Integer, nullable=True)
    speed = Column(Float, nullable=True)
    bearing = Column(Float, nullable=True)
    altitude = Column(Float, nullable=True)
    battery_level = Column(Integer, nullable=True)
    network_type = Column(String(32), nullable=True)
    sample_source = Column(Enum(SampleSource), default=SampleSource.GPS)
    uploaded = Column(Boolean, default=False)
    encrypted = Column(Boolean, default=False)
    created_at = Column(BigInteger, nullable=False)
    
    # Relationship
    tourist = relationship("Tourist", back_populates="location_samples")
    
    __table_args__ = (
        Index('idx_tourist_time', 'tourist_id', 'timestamp'),
        Index('idx_location', 'lat', 'lon'),
        Index('idx_uploaded', 'uploaded'),
        Index('idx_live_session', 'live_session_id'),
    )

class Geofence(Base):
    __tablename__ = "geofences"
    
    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    geometry = Column(JSON, nullable=False)
    geometry_type = Column(Enum(GeometryType), default=GeometryType.POLYGON)
    risk_level = Column(Enum(RiskLevel), default=RiskLevel.MEDIUM)
    active = Column(Boolean, default=True)
    created_by = Column(String(128), nullable=False)
    region = Column(String(128), nullable=True)
    expires_at = Column(BigInteger, nullable=True)
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=True)
    
    __table_args__ = (
        Index('idx_active', 'active'),
        Index('idx_risk_level', 'risk_level'),
        Index('idx_region', 'region'),
    )

class SafetyScore(Base):
    __tablename__ = "safety_scores"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False, unique=True)
    score = Column(Float, nullable=False)
    components = Column(JSON, nullable=True)
    calculation_version = Column(String(16), default='v1.0')
    last_updated = Column(BigInteger, nullable=False)
    valid_until = Column(BigInteger, nullable=True)
    
    # Relationship
    tourist = relationship("Tourist", back_populates="safety_scores")
    
    __table_args__ = (
        Index('idx_score', 'score'),
        Index('idx_last_updated', 'last_updated'),
    )

class Alert(Base):
    __tablename__ = "alerts"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    alert_type = Column(Enum(AlertType), nullable=False)
    severity = Column(Enum(AlertSeverity), default=AlertSeverity.MEDIUM)
    title = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    status = Column(Enum(AlertStatus), default=AlertStatus.ACTIVE)
    location_lat = Column(DECIMAL(10, 7), nullable=True)
    location_lon = Column(DECIMAL(10, 7), nullable=True)
    evidence_hash = Column(String(128), nullable=True)
    assigned_unit = Column(String(128), nullable=True)
    assigned_at = Column(BigInteger, nullable=True)
    live_session_id = Column(String(64), ForeignKey('live_share_sessions.id'), nullable=True)
    created_at = Column(BigInteger, nullable=False)
    acknowledged_at = Column(BigInteger, nullable=True)
    resolved_at = Column(BigInteger, nullable=True)
    extra_data = Column(JSON, nullable=True)
    
    # Relationships
    tourist = relationship("Tourist", back_populates="alerts")
    live_session = relationship("LiveShareSession", back_populates="alerts")
    evidence_items = relationship("Evidence", back_populates="alert", cascade="all, delete-orphan")
    anomaly_events = relationship("AnomalyEvent", back_populates="alert", cascade="all, delete-orphan")
    call_attempts = relationship("CallAttempt", back_populates="alert", cascade="all, delete-orphan")
    
    __table_args__ = (
        Index('idx_tourist_alerts', 'tourist_id', 'created_at'),
        Index('idx_status', 'status'),
        Index('idx_type_severity', 'alert_type', 'severity'),
        Index('idx_live_session', 'live_session_id'),
    )

class Evidence(Base):
    __tablename__ = "evidence"
    
    id = Column(String(64), primary_key=True, index=True)
    alert_id = Column(BigInteger, ForeignKey('alerts.id'), nullable=False)
    media_type = Column(Enum(MediaType), nullable=False)
    storage_path = Column(String(512), nullable=False)
    sha256_hash = Column(String(64), nullable=False)
    tx_hash = Column(String(66), nullable=True)
    uploaded = Column(Boolean, default=False)
    file_size = Column(BigInteger, nullable=True)
    duration_seconds = Column(Integer, nullable=True)
    created_at = Column(BigInteger, nullable=False)
    
    # Relationship
    alert = relationship("Alert", back_populates="evidence_items")
    
    __table_args__ = (
        Index('idx_alert', 'alert_id'),
        Index('idx_uploaded', 'uploaded'),
        Index('idx_created', 'created_at'),
    )

class AnomalyEvent(Base):
    __tablename__ = "anomaly_events"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    alert_id = Column(BigInteger, ForeignKey('alerts.id'), nullable=False)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    anomaly_type = Column(Enum(AnomalyType), nullable=False)
    confidence_score = Column(Float, nullable=True)
    triggering_data = Column(JSON, comment='Snapshot of sensor data that caused the alert')
    created_at = Column(BigInteger, nullable=False)
    
    # Relationships
    alert = relationship("Alert", back_populates="anomaly_events")
    tourist = relationship("Tourist")
    
    __table_args__ = (
        Index('idx_tourist_anomaly', 'tourist_id', 'anomaly_type'),
        Index('idx_created', 'created_at'),
    )

class Entity(Base):
    __tablename__ = "entities"
    
    id = Column(String(64), primary_key=True, index=True)
    type = Column(Enum(EntityType), nullable=False)
    name = Column(String(255), nullable=False)
    lat = Column(DECIMAL(10, 7), nullable=False)
    lon = Column(DECIMAL(10, 7), nullable=False)
    contact_info = Column(JSON, nullable=True)
    verification_status = Column(Enum(VerificationStatus), default=VerificationStatus.PENDING)
    verification_tier = Column(Enum(VerificationTier), default=VerificationTier.BRONZE)
    last_verified_at = Column(BigInteger, nullable=True)
    onchain_tx_hash = Column(String(66), nullable=True)
    created_at = Column(BigInteger, nullable=False)
    
    # Relationships
    ratings = relationship("EntityRating", back_populates="entity", cascade="all, delete-orphan")
    
    __table_args__ = (
        Index('idx_type_status', 'type', 'verification_status'),
        Index('idx_location', 'lat', 'lon'),
        Index('idx_verification', 'verification_status', 'verification_tier'),
    )

class EntityRating(Base):
    __tablename__ = "entity_ratings"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    entity_id = Column(String(64), ForeignKey('entities.id'), nullable=False)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    rating = Column(Integer, nullable=False, comment='1-5 stars')
    comment = Column(Text, nullable=True)
    created_at = Column(BigInteger, nullable=False)
    
    # Relationships
    entity = relationship("Entity", back_populates="ratings")
    tourist = relationship("Tourist", back_populates="entity_ratings")
    
    __table_args__ = (
        UniqueConstraint('tourist_id', 'entity_id', name='unique_tourist_entity'),
        Index('idx_entity_rating', 'entity_id', 'rating'),
    )

class Authority(Base):
    __tablename__ = "authorities"
    
    eth_address = Column(String(42), primary_key=True)
    name = Column(String(255), nullable=False)
    role = Column(Enum(AuthorityRole), nullable=False)
    region = Column(String(128), nullable=True)
    department = Column(String(255), nullable=True)
    contact_info = Column(JSON, nullable=True)
    permissions = Column(JSON, nullable=True)
    status = Column(Enum(AuthorityStatus), default=AuthorityStatus.ACTIVE)
    added_by = Column(String(42), nullable=True)
    added_at = Column(BigInteger, nullable=False)
    last_active = Column(BigInteger, nullable=True)
    notes = Column(Text, nullable=True)
    
    __table_args__ = (
        Index('idx_role_region', 'role', 'region'),
        Index('idx_status', 'status'),
    )

class AccessLog(Base):
    __tablename__ = "access_logs"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    token_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    accessor_address = Column(String(42), nullable=False)
    accessor_name = Column(String(255), nullable=True)
    fields_requested = Column(Text, nullable=False)
    access_granted = Column(Boolean, default=True)
    reason_denied = Column(Text, nullable=True)
    timestamp = Column(BigInteger, nullable=False)
    tx_hash = Column(String(66), nullable=True)
    ip_address = Column(String(45), nullable=True)
    user_agent = Column(Text, nullable=True)
    notes = Column(Text, nullable=True)
    
    # Relationship
    token = relationship("Tourist", back_populates="access_logs")
    
    __table_args__ = (
        Index('idx_token_access', 'token_id', 'timestamp'),
        Index('idx_accessor', 'accessor_address', 'timestamp'),
        Index('idx_timestamp', 'timestamp'),
    )

class CallAttempt(Base):
    __tablename__ = "call_attempts"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    alert_id = Column(BigInteger, ForeignKey('alerts.id'), nullable=False)
    phone_number = Column(String(20), nullable=False)
    attempt_ts = Column(BigInteger, nullable=False)
    result = Column(Enum(CallResult), nullable=False)
    provider_log_id = Column(String(128), nullable=True)
    
    # Relationship
    alert = relationship("Alert", back_populates="call_attempts")
    
    __table_args__ = (
        Index('idx_alert', 'alert_id'),
        Index('idx_result', 'result'),
    )

class HeatmapAggregate(Base):
    __tablename__ = "heatmap_aggregates"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    grid_cell_id = Column(String(32), nullable=False)
    time_bucket = Column(String(16), nullable=False)
    bucket_type = Column(Enum(BucketType), default=BucketType.HOURLY)
    tourist_count = Column(Integer, default=0)
    total_samples = Column(Integer, default=0)
    avg_density = Column(Float, default=0.0)
    risk_events = Column(Integer, default=0)
    last_updated = Column(BigInteger, nullable=False)
    extra_data = Column(JSON, nullable=True)
    
    __table_args__ = (
        UniqueConstraint('grid_cell_id', 'time_bucket', 'bucket_type', name='unique_cell_bucket'),
        Index('idx_time_bucket', 'time_bucket'),
        Index('idx_grid_cell', 'grid_cell_id'),
        Index('idx_last_updated', 'last_updated'),
    )

class EmergencyContact(Base):
    __tablename__ = "emergency_contacts"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False)
    contact_name = Column(String(255), nullable=False)
    contact_relationship = Column(String(100), nullable=True)
    phone_number = Column(String(20), nullable=False)
    email = Column(String(255), nullable=True)
    priority_order = Column(Integer, default=1)
    active = Column(Boolean, default=True)
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=True)
    
    # Relationship
    tourist = relationship("Tourist", back_populates="emergency_contacts")
    
    __table_args__ = (
        Index('idx_tourist_priority', 'tourist_id', 'priority_order'),
    )

class SystemConfig(Base):
    __tablename__ = "system_config"
    
    config_key = Column(String(128), primary_key=True)
    config_value = Column(JSON, nullable=False)
    description = Column(Text, nullable=True)
    updated_by = Column(String(128), nullable=True)
    updated_at = Column(BigInteger, nullable=False)
    
    
class HealthProfile(Base):
    __tablename__ = "health_profiles"
    
    id = Column(BigInteger, primary_key=True, autoincrement=True)
    tourist_id = Column(String(64), ForeignKey('tourists.id'), nullable=False, unique=True)
    health_profile_json = Column(JSON, nullable=False, comment='Structured health data for safety calculations')
    source_file_hash = Column(String(64), nullable=True, comment='Hash of medical document')
    llm_analysis_version = Column(String(20), default='v1.0')
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=False)
    
    # Relationship
    tourist = relationship("Tourist", backref="health_profile")
    
    __table_args__ = (
        Index('idx_tourist', 'tourist_id'),
        Index('idx_updated_at', 'updated_at'),
        Index('idx_health_profile_source', 'source_file_hash'),
    )
    
class CityKnowledgeBase(Base):
    __tablename__ = "city_knowledge_bases"

    id = Column(BigInteger, primary_key=True, autoincrement=True)
    city_name = Column(String(100), nullable=False)
    city_name_normalized = Column(String(100), nullable=False, unique=True, index=True)
    file_path = Column(String(512), nullable=False)
    file_size_bytes = Column(BigInteger, nullable=True)
    version = Column(Integer, default=1)
    description = Column(Text, nullable=True)

    # avoid using attribute name `metadata` (reserved). Use a different attribute name
    metadata_json = Column('metadata', JSON, nullable=True)

    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=False)
    created_by = Column(String(128), nullable=True)
    is_active = Column(Boolean, default=True)

    __table_args__ = (
        Index('idx_city_name', 'city_name_normalized'),
        Index('idx_active', 'is_active'),
        Index('idx_updated_at', 'updated_at'),
    )

# Database utility functions
@contextmanager
def get_db_session() -> Session:
    """Get a database session with automatic cleanup"""
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception as e:
        session.rollback()
        logger.error(f"Database error: {e}")
        raise
    finally:
        session.close()

def get_db() -> Session:
    """Dependency for FastAPI to get database session"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def init_database():
    """Initialize database and create all tables"""
    try:
        # Create all tables
        Base.metadata.create_all(bind=engine)
        logger.info("Database tables created successfully")
        
        # Insert default configurations if they don't exist
        with get_db_session() as session:
            existing_configs = session.query(SystemConfig).count()
            if existing_configs == 0:
                import time
                current_time = int(time.time() * 1000)
                
                default_configs = [
                    SystemConfig(
                        config_key='location_retention_days',
                        config_value=30,
                        description='Days to keep raw location samples',
                        updated_at=current_time
                    ),
                    SystemConfig(
                        config_key='safety_score_weights',
                        config_value={
                            "location_risk": 0.3,
                            "movement_pattern": 0.2,
                            "time_factors": 0.2,
                            "battery_connectivity": 0.3
                        },
                        description='Weights for safety score calculation',
                        updated_at=current_time
                    ),
                    SystemConfig(
                        config_key='alert_thresholds',
                        config_value={
                            "geofence_high_risk": 1800,
                            "offline_timeout": 3600,
                            "low_battery": 15
                        },
                        description='Thresholds in seconds/percentage for various alerts',
                        updated_at=current_time
                    ),
                    SystemConfig(
                        config_key='data_retention_policy',
                        config_value={
                            "location_samples": 30,
                            "access_logs": 365,
                            "alerts": 1095
                        },
                        description='Data retention in days',
                        updated_at=current_time
                    ),
                    SystemConfig(
                        config_key='otp_expiry_minutes',
                        config_value=5,
                        description='OTP expiry time in minutes',
                        updated_at=current_time
                    ),
                    SystemConfig(
                        config_key='mobile_hash_pepper',
                        config_value='CHANGE_IN_PRODUCTION_VERY_SECRET',
                        description='Pepper for mobile number hashing',
                        updated_at=current_time
                    )
                ]
                
                session.add_all(default_configs)
                logger.info("Default system configurations added")
        
        return True
    except Exception as e:
        logger.error(f"Database initialization failed: {e}")
        raise

def check_database_connection() -> bool:
    """Check if database connection is working"""
    try:
        with get_db_session() as session:
            session.execute(text("SELECT 1"))
        return True
    except Exception as e:
        logger.error(f"Database connection check failed: {e}")
        return False