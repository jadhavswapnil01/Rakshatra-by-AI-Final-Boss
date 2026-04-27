# server/blockchain.py
import os
import json
import logging
from typing import Dict, Any, Optional, Tuple
from web3 import Web3
from web3.exceptions import ContractLogicError, TransactionNotFound
from eth_account import Account

logger = logging.getLogger(__name__)

class BlockchainError(Exception):
    """Custom exception for blockchain operations"""
    pass

class BlockchainManager:
    def __init__(self):
        self.rpc_url = os.getenv("RPC_URL", "http://127.0.0.1:8545")
        self.contract_address = os.getenv("CONTRACT_ADDRESS")
        self.private_key = os.getenv("PRIVATE_KEY")
        
        if not self.contract_address:
            raise BlockchainError("CONTRACT_ADDRESS not set in environment")
        if not self.private_key:
            raise BlockchainError("PRIVATE_KEY not set in environment")
        
        # Initialize Web3
        self.w3 = Web3(Web3.HTTPProvider(self.rpc_url))
        if not self.w3.is_connected():
            raise BlockchainError(f"Cannot connect to blockchain at {self.rpc_url}")
        
        # Initialize account
        self.account = Account.from_key(self.private_key)
        
        # Load contract ABI and create contract instance
        self._load_contract()
        
        logger.info(f"Blockchain manager initialized. Account: {self.account.address}")
    
    def _load_contract(self):
        """Load contract ABI and create contract instance"""
        abi_path = "build/contracts/DigitalTouristID.json"
        
        if not os.path.exists(abi_path):
            logger.error(f"Contract ABI not found at {abi_path}")
            return # Don't raise, just stop loading

        try:
            with open(abi_path, 'r') as f:
                artifact = json.load(f)
            
            self.abi = artifact["abi"]
            self.contract_address = Web3.to_checksum_address(self.contract_address)
            self.contract = self.w3.eth.contract(address=self.contract_address, abi=self.abi)
            
            # Verify contract exists
            code = self.w3.eth.get_code(self.contract_address)
            if code == b'':
                logger.warning(f"⚠️ No contract code found at {self.contract_address}. Migration required.")
                self.contract = None # Reset so app knows it's not ready
        except Exception as e:
            logger.error(f"Failed to load contract: {e}")
            self.contract = None
    
    def _build_transaction(self, contract_function, gas_limit: int = 500000) -> Dict[str, Any]:
        """Build a transaction for a contract function"""
        try:
            nonce = self.w3.eth.get_transaction_count(self.account.address)
            gas_price = self.w3.eth.gas_price
            
            transaction = contract_function.build_transaction({
                'from': self.account.address,
                'nonce': nonce,
                'gas': gas_limit,
                'gasPrice': gas_price
            })
            
            return transaction
        except Exception as e:
            raise BlockchainError(f"Failed to build transaction: {e}")
    
    def _send_transaction(self, transaction: Dict[str, Any]) -> Dict[str, Any]:
        """Sign and send a transaction"""
        try:
            # Sign transaction
            signed_tx = self.account.sign_transaction(transaction)
            
            # Send transaction
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
            
            # Wait for receipt
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
            
            if receipt.status == 0:
                raise BlockchainError("Transaction failed on-chain (reverted)")
            
            return {
                'tx_hash': receipt.transactionHash.hex(),
                'block_number': receipt.blockNumber,
                'gas_used': receipt.gasUsed,
                'status': receipt.status
            }
            
        except Exception as e:
            raise BlockchainError(f"Transaction failed: {e}")
        
    
    def mint_tourist_id(
        self,
        token_id: str,
        data_hash: str,
        pointer: str,
        valid_from: int,
        valid_till: int
    ) -> Dict[str, Any]:
        """
        Mint a new tourist ID on the blockchain
        
        Args:
            token_id: Unique token identifier
            data_hash: SHA-256 hash of encrypted data (hex string)
            pointer: Data pointer (e.g., "local:DTID-xxx")
            valid_from: Unix timestamp
            valid_till: Unix timestamp
        """
        try:
            # Ensure data_hash is properly formatted as bytes32
            if data_hash.startswith('0x'):
                data_hash_bytes = Web3.to_bytes(hexstr=data_hash)
            else:
                data_hash_bytes = Web3.to_bytes(hexstr='0x' + data_hash)
            
            if len(data_hash_bytes) != 32:
                raise BlockchainError(f"data_hash must be 32 bytes, got {len(data_hash_bytes)}")
            
            # Build transaction
            contract_function = self.contract.functions.mintTouristID(
                token_id,
                data_hash_bytes,
                pointer,
                valid_from,
                valid_till
            )
            
            transaction = self._build_transaction(contract_function, gas_limit=600000)
            result = self._send_transaction(transaction)
            
            logger.info(f"Minted tourist ID {token_id}. TX: {result['tx_hash']}")
            return result
            
        except ContractLogicError as e:
            raise BlockchainError(f"Contract error during mint: {e}")
        except Exception as e:
            raise BlockchainError(f"Failed to mint tourist ID: {e}")
    
    def revoke_tourist_id(self, token_id: str, reason: str) -> Dict[str, Any]:
        """Revoke a tourist ID"""
        try:
            contract_function = self.contract.functions.revokeTouristID(token_id, reason)
            transaction = self._build_transaction(contract_function)
            result = self._send_transaction(transaction)
            
            logger.info(f"Revoked tourist ID {token_id}. TX: {result['tx_hash']}")
            return result
            
        except ContractLogicError as e:
            raise BlockchainError(f"Contract error during revocation: {e}")
        except Exception as e:
            raise BlockchainError(f"Failed to revoke tourist ID: {e}")
    # In server/blockchain.py, inside the BlockchainManager class

    def update_data_hash(self, token_id: str, new_data_hash: str) -> Dict[str, Any]:
        """Update the data hash for a token on the blockchain"""
        try:
            if new_data_hash.startswith('0x'):
                data_hash_bytes = Web3.to_bytes(hexstr=new_data_hash)
            else:
                data_hash_bytes = Web3.to_bytes(hexstr='0x' + new_data_hash)

            if len(data_hash_bytes) != 32:
                raise BlockchainError(f"new_data_hash must be 32 bytes, got {len(data_hash_bytes)}")

            contract_function = self.contract.functions.updateDataHash(token_id, data_hash_bytes)
            transaction = self._build_transaction(contract_function)
            result = self._send_transaction(transaction)

            logger.info(f"Updated data hash for {token_id}. TX: {result['tx_hash']}")
            return result

        except ContractLogicError as e:
            raise BlockchainError(f"Contract error updating data hash: {e}")
        except Exception as e:
            raise BlockchainError(f"Failed to update data hash: {e}")
    def log_access(self, token_id: str, accessor_address: str, fields: str) -> Dict[str, Any]:
        """Log data access on the blockchain"""
        try:
            accessor_address = Web3.to_checksum_address(accessor_address)
            
            contract_function = self.contract.functions.logAccess(
                token_id,
                accessor_address,
                fields
            )
            
            transaction = self._build_transaction(contract_function, gas_limit=400000)
            result = self._send_transaction(transaction)
            
            logger.info(f"Logged access to {token_id} by {accessor_address}. TX: {result['tx_hash']}")
            return result
            
        except ContractLogicError as e:
            raise BlockchainError(f"Contract error during access log: {e}")
        except Exception as e:
            raise BlockchainError(f"Failed to log access: {e}")
    
    def get_token(self, token_id: str) -> Optional[Tuple[str, str, int, int, bool]]:
        """
        Get token information from blockchain
        
        Returns:
            Tuple of (data_hash_hex, pointer, valid_from, valid_till, revoked)
            or None if token doesn't exist
        """
        try:
            result = self.contract.functions.getToken(token_id).call()
            data_hash_bytes, pointer, valid_from, valid_till, revoked = result
            
            # Convert bytes32 to hex string
            data_hash_hex = data_hash_bytes.hex()
            
            return data_hash_hex, pointer, valid_from, valid_till, revoked
            
        except ContractLogicError:
            # Token doesn't exist
            return None
        except Exception as e:
            raise BlockchainError(f"Failed to get token info: {e}")
    
    def verify_token_validity(self, token_id: str) -> Dict[str, Any]:
        """
        Verify if a token is valid (exists, not revoked, not expired)
        
        Returns:
            Dict with validation status and details
        """
        try:
            token_info = self.get_token(token_id)
            
            if not token_info:
                return {
                    'valid': False,
                    'reason': 'Token does not exist',
                    'exists': False
                }
            
            data_hash, pointer, valid_from, valid_till, revoked = token_info
            current_time = self.w3.eth.get_block('latest').timestamp
            
            if revoked:
                return {
                    'valid': False,
                    'reason': 'Token is revoked',
                    'exists': True,
                    'revoked': True
                }
            
            if current_time < valid_from:
                return {
                    'valid': False,
                    'reason': 'Token not yet valid',
                    'exists': True,
                    'not_yet_valid': True
                }
            
            if current_time > valid_till:
                return {
                    'valid': False,
                    'reason': 'Token has expired',
                    'exists': True,
                    'expired': True
                }
            
            return {
                'valid': True,
                'exists': True,
                'data_hash': data_hash,
                'pointer': pointer,
                'valid_from': valid_from,
                'valid_till': valid_till
            }
            
        except Exception as e:
            raise BlockchainError(f"Token validation failed: {e}")
    
    def get_access_events(self, token_id: Optional[str] = None, from_block: int = 0) -> list:
        """Get access log events from the blockchain"""
        try:
            event_filter = self.contract.events.AccessLogged.create_filter(
                fromBlock=from_block,
                toBlock='latest'
            )
            
            events = []
            for event in event_filter.get_all_entries():
                event_data = {
                    'token_id': event.args.tokenId,
                    'accessor': event.args.accessor,
                    'fields': event.args.fields,
                    'timestamp': event.args.timestamp,
                    'block_number': event.blockNumber,
                    'tx_hash': event.transactionHash.hex()
                }
                
                if token_id is None or event_data['token_id'] == token_id:
                    events.append(event_data)
            
            return events
            
        except Exception as e:
            raise BlockchainError(f"Failed to get access events: {e}")
    
    def add_issuer(self, issuer_address: str) -> Dict[str, Any]:
        """Add a new issuer (only owner can do this)"""
        try:
            issuer_address = Web3.to_checksum_address(issuer_address)
            
            contract_function = self.contract.functions.addIssuer(issuer_address)
            transaction = self._build_transaction(contract_function)
            result = self._send_transaction(transaction)
            
            logger.info(f"Added issuer {issuer_address}. TX: {result['tx_hash']}")
            return result
            
        except ContractLogicError as e:
            raise BlockchainError(f"Contract error adding issuer: {e}")
        except Exception as e:
            raise BlockchainError(f"Failed to add issuer: {e}")
    
    def check_connection(self) -> Dict[str, Any]:
        """Check blockchain connection and account status"""
        try:
            latest_block = self.w3.eth.get_block('latest')
            balance = self.w3.eth.get_balance(self.account.address)
            
            return {
                'connected': True,
                'latest_block': int(latest_block.number), # Ensure int
                'account': self.account.address,
                'balance_wei': int(balance), # Ensure int
                'balance_eth': str(self.w3.from_wei(balance, 'ether')), # FIX: Convert Decimal to String here
                'contract_address': self.contract_address
            }
        except Exception as e:
            return {
                'connected': False,
                'error': str(e)
            }

# Global instance
blockchain_manager = None

def get_blockchain_manager() -> BlockchainManager:
    """Get or create blockchain manager instance"""
    global blockchain_manager
    if blockchain_manager is None:
        blockchain_manager = BlockchainManager()
    return blockchain_manager

def init_blockchain():
    """Initialize blockchain connection"""
    try:
        manager = get_blockchain_manager()
        status = manager.check_connection()
        if status['connected']:
            logger.info(f"Blockchain initialized. Block: {status['latest_block']}, Account: {status['account']}")
        else:
            logger.error(f"Blockchain connection failed: {status.get('error', 'Unknown error')}")
        return status
    except Exception as e:
        logger.error(f"Failed to initialize blockchain: {e}")
        raise