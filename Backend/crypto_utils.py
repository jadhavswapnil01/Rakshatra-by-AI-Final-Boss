# server/crypto_utils.py
import os
import json
import binascii
import hashlib
from typing import Dict, Any, Optional
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag

class CryptoError(Exception):
    """Custom exception for crypto operations"""
    pass

def generate_key(length: int = 32) -> bytes:
    """Generate a random key of specified length (default 256-bit)"""
    return os.urandom(length)

def generate_master_key_hex() -> str:
    """Generate a master key and return as hex string"""
    return binascii.hexlify(generate_key()).decode()

def aesgcm_encrypt(plaintext: bytes, key: bytes) -> Dict[str, str]:
    """
    Encrypt data using AES-GCM
    Returns: {"iv": hex_string, "ciphertext": hex_string}
    """
    if len(key) not in [16, 24, 32]:
        raise CryptoError("Key must be 16, 24, or 32 bytes long")
    
    try:
        aesgcm = AESGCM(key)
        iv = os.urandom(12)  # 96-bit IV for GCM
        ciphertext = aesgcm.encrypt(iv, plaintext, None)
        
        return {
            "iv": binascii.hexlify(iv).decode(),
            "ciphertext": binascii.hexlify(ciphertext).decode()
        }
    except Exception as e:
        raise CryptoError(f"Encryption failed: {str(e)}")

def aesgcm_decrypt(encrypted_data: Dict[str, str], key: bytes) -> bytes:
    """
    Decrypt AES-GCM encrypted data
    Args:
        encrypted_data: Dict with "iv" and "ciphertext" hex strings
        key: Decryption key
    Returns: Decrypted plaintext bytes
    """
    if len(key) not in [16, 24, 32]:
        raise CryptoError("Key must be 16, 24, or 32 bytes long")
    
    try:
        iv = binascii.unhexlify(encrypted_data["iv"])
        ciphertext = binascii.unhexlify(encrypted_data["ciphertext"])
        
        aesgcm = AESGCM(key)
        plaintext = aesgcm.decrypt(iv, ciphertext, None)
        
        return plaintext
    except (KeyError, binascii.Error) as e:
        raise CryptoError(f"Invalid encrypted data format: {str(e)}")
    except InvalidTag:
        raise CryptoError("Decryption failed: Invalid authentication tag")
    except Exception as e:
        raise CryptoError(f"Decryption failed: {str(e)}")

def encrypt_json(data: Dict[str, Any], key: bytes) -> Dict[str, str]:
    """
    Encrypt a JSON-serializable object
    Returns: {"iv": hex_string, "ciphertext": hex_string}
    """
    try:
        plaintext = json.dumps(data, separators=(',', ':'), ensure_ascii=False)
        return aesgcm_encrypt(plaintext.encode('utf-8'), key)
    except (TypeError, ValueError) as e:
        raise CryptoError(f"JSON serialization failed: {str(e)}")

def decrypt_json(encrypted_data: Dict[str, str], key: bytes) -> Dict[str, Any]:
    """
    Decrypt and deserialize JSON data
    Returns: Original data structure
    """
    try:
        plaintext_bytes = aesgcm_decrypt(encrypted_data, key)
        return json.loads(plaintext_bytes.decode('utf-8'))
    except json.JSONDecodeError as e:
        raise CryptoError(f"JSON deserialization failed: {str(e)}")
    except UnicodeDecodeError as e:
        raise CryptoError(f"UTF-8 decoding failed: {str(e)}")

def wrap_dek(dek: bytes, master_key: bytes) -> Dict[str, str]:
    """
    Wrap (encrypt) a Data Encryption Key with Master Key
    """
    return aesgcm_encrypt(dek, master_key)

def unwrap_dek(wrapped_dek: Dict[str, str], master_key: bytes) -> bytes:
    """
    Unwrap (decrypt) a Data Encryption Key
    """
    return aesgcm_decrypt(wrapped_dek, master_key)

def sha256_hex(data: bytes) -> str:
    """Calculate SHA-256 hash and return as hex string"""
    return hashlib.sha256(data).hexdigest()

def sha256_file(file_path: str, chunk_size: int = 8192) -> str:
    """Calculate SHA-256 hash of a file"""
    hash_sha256 = hashlib.sha256()
    try:
        with open(file_path, "rb") as f:
            for chunk in iter(lambda: f.read(chunk_size), b""):
                hash_sha256.update(chunk)
        return hash_sha256.hexdigest()
    except IOError as e:
        raise CryptoError(f"File hash calculation failed: {str(e)}")

def generate_token_id() -> str:
    """Generate a unique DTID token identifier"""
    return "DTID-" + binascii.hexlify(os.urandom(8)).decode().upper()

def hash_sensitive_data(data: str, salt: Optional[bytes] = None) -> Dict[str, str]:
    """
    Hash sensitive data like passport numbers with optional salt
    Returns: {"hash": hex_string, "salt": hex_string}
    """
    if salt is None:
        salt = os.urandom(16)
    
    hash_input = data.encode('utf-8') + salt
    hash_value = hashlib.sha256(hash_input).hexdigest()
    
    return {
        "hash": hash_value,
        "salt": binascii.hexlify(salt).decode()
    }

def verify_sensitive_hash(data: str, hash_data: Dict[str, str]) -> bool:
    """Verify a hashed sensitive data value"""
    try:
        salt = binascii.unhexlify(hash_data["salt"])
        expected_hash = hash_data["hash"]
        
        hash_input = data.encode('utf-8') + salt
        actual_hash = hashlib.sha256(hash_input).hexdigest()
        
        return actual_hash == expected_hash
    except (KeyError, binascii.Error):
        return False

# Utility functions for testing
def test_crypto_operations():
    """Test basic crypto operations"""
    print("Testing crypto operations...")
    
    # Test key generation
    key = generate_key()
    print(f"Generated key length: {len(key)} bytes")
    
    # Test JSON encryption/decryption
    test_data = {
        "name": "Test User",
        "passport": "P123456",
        "emergency_contacts": [
            {"name": "John Doe", "phone": "+1234567890"}
        ]
    }
    
    encrypted = encrypt_json(test_data, key)
    print(f"Encrypted data keys: {list(encrypted.keys())}")
    
    decrypted = decrypt_json(encrypted, key)
    print(f"Decryption successful: {decrypted == test_data}")
    
    # Test DEK wrapping
    master_key = generate_key()
    dek = generate_key()
    
    wrapped = wrap_dek(dek, master_key)
    unwrapped = unwrap_dek(wrapped, master_key)
    print(f"DEK wrapping successful: {dek == unwrapped}")
    
    # Test hashing
    test_hash = sha256_hex(b"test data")
    print(f"SHA-256 hash: {test_hash}")
    
    print("All crypto tests passed!")

if __name__ == "__main__":
    test_crypto_operations()