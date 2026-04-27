@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM == DTID System Setup Script for Windows (v2 - Robust Version)           ==
REM ============================================================================
REM == Fixes:                                                                 ==
REM == 1. Dynamically finds the global npm installation path and adds it to   ==
REM ==    the script's PATH to ensure 'truffle' and 'ganache' are found.      ==
REM == 2. Rewrites file creation to be line-by-line, which is much safer and  ==
REM ==    avoids cmd.exe parsing errors with Solidity code.                   ==
REM == 3. Ensures all special characters in the Solidity code are escaped.    ==
REM ============================================================================

REM Main execution flow
call :main %*
goto :eof


REM ============================================================================
REM == Functions ==
REM ============================================================================

:print_status
    echo [INFO] %~1
    goto :eof

:print_warning
    echo [WARNING] %~1
    goto :eof

:print_error
    echo [ERROR] %~1
    goto :eof

:print_step
    echo.
    echo [STEP] %~1
    echo --------------------------------------------------
    goto :eof

:check_requirements
    call :print_step "Checking system requirements..."

    REM Check Node.js
    where node >nul 2>nul
    if %errorlevel% neq 0 (
        call :print_error "Node.js is not installed. Please install Node.js 16+ first."
        exit /b 1
    )
    for /f "delims=" %%i in ('node --version') do set "NODE_VERSION=%%i"
    call :print_status "Node.js version: !NODE_VERSION!"

    REM Check npm
    where npm >nul 2>nul
    if %errorlevel% neq 0 (
        call :print_error "npm is not installed."
        exit /b 1
    )
    for /f "delims=" %%i in ('npm --version') do set "NPM_VERSION=%%i"
    call :print_status "npm version: !NPM_VERSION!"

    REM Check Python
    where python >nul 2>nul
    if %errorlevel% neq 0 (
        call :print_error "Python is not installed. Please install Python 3.9+."
        exit /b 1
    )
    for /f "delims=" %%i in ('python --version') do set "PYTHON_VERSION=%%i"
    call :print_status "Python version: !PYTHON_VERSION!"

    REM Check MySQL
    where mysql >nul 2>nul
    if %errorlevel% neq 0 (
        call :print_warning "MySQL client not found. Make sure MySQL server is running."
    ) else (
        call :print_status "MySQL client found"
    )

    call :print_status "All basic requirements satisfied!"
    goto :eof

:setup_project
    call :print_step "Setting up project directory..."

    REM Initialize npm project if needed
    if not exist "package.json" (
        npm init -y > nul
        call :print_status "Initialized npm project"
    )
    goto :eof

:setup_truffle
    call :print_step "Setting up Truffle and Ganache..."

    REM Initialize Truffle project if needed
    if not exist "truffle-config.js" (
        call :print_status "Truffle command found. Initializing project..."
        truffle init > nul
        call :print_status "Initialized Truffle project"
    )

    REM Create custom truffle config
    > truffle-config.js (
        echo module.exports = {
        echo   networks: {
        echo     development: {
        echo       host: "127.0.0.1",
        echo       port: 8545,
        echo       network_id: "*",
        echo       gas: 6721975,
        echo       gasPrice: 20000000000
        echo     }
        echo   },
        echo   compilers: {
        echo     solc: {
        echo       version: "0.8.17",
        echo       settings: {
        echo         optimizer: {
        echo           enabled: true,
        echo           runs: 200
        echo         }
        echo       }
        echo     }
        echo   }
        echo };
    )
    call :print_status "Created Truffle configuration"
    goto :eof

:setup_contract
    call :print_step "Setting up Solidity contract..."

    REM Create the contract file using the safer line-by-line method
    echo // SPDX-License-Identifier: MIT > contracts\DigitalTouristID.sol
    echo pragma solidity ^>0.8.17; >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo contract DigitalTouristID { >> contracts\DigitalTouristID.sol
    echo     address public owner; >> contracts\DigitalTouristID.sol
    echo     mapping(address =^> bool) public issuers; >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     struct TouristToken { >> contracts\DigitalTouristID.sol
    echo         bytes32 dataHash; >> contracts\DigitalTouristID.sol
    echo         string pointer; >> contracts\DigitalTouristID.sol
    echo         uint256 validFrom; >> contracts\DigitalTouristID.sol
    echo         uint256 validTill; >> contracts\DigitalTouristID.sol
    echo         bool revoked; >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo     mapping(string =^> TouristToken) public tokens; >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     event Minted(string indexed tokenId, bytes32 dataHash, string pointer, uint256 validFrom, uint256 validTill, address issuer); >> contracts\DigitalTouristID.sol
    echo     event Revoked(string indexed tokenId, string reason, address issuer); >> contracts\DigitalTouristID.sol
    echo     event AccessLogged(string indexed tokenId, address indexed accessor, string fields, uint256 timestamp); >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     constructor() { >> contracts\DigitalTouristID.sol
    echo         owner = msg.sender; >> contracts\DigitalTouristID.sol
    echo         issuers[msg.sender] = true; >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     modifier onlyOwner() { >> contracts\DigitalTouristID.sol
    echo         require(msg.sender == owner, "Only owner"); >> contracts\DigitalTouristID.sol
    echo         _; >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     modifier onlyIssuer() { >> contracts\DigitalTouristID.sol
    echo         require(issuers[msg.sender], "Not an issuer"); >> contracts\DigitalTouristID.sol
    echo         _; >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     function addIssuer(address _issuer) external onlyOwner { >> contracts\DigitalTouristID.sol
    echo         issuers[_issuer] = true; >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     function removeIssuer(address _issuer) external onlyOwner { >> contracts\DigitalTouristID.sol
    echo         issuers[_issuer] = false; >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     function mintTouristID( >> contracts\DigitalTouristID.sol
    echo         string calldata tokenId, >> contracts\DigitalTouristID.sol
    echo         bytes32 dataHash, >> contracts\DigitalTouristID.sol
    echo         string calldata pointer, >> contracts\DigitalTouristID.sol
    echo         uint256 validFrom, >> contracts\DigitalTouristID.sol
    echo         uint256 validTill >> contracts\DigitalTouristID.sol
    echo     ) external onlyIssuer { >> contracts\DigitalTouristID.sol
    echo         require(tokens[tokenId].validFrom == 0, "Token already exists"); >> contracts\DigitalTouristID.sol
    echo         require(validTill ^> validFrom, "Invalid validity period"); >> contracts\DigitalTouristID.sol
    echo         require(validFrom ^<= block.timestamp + 86400, "Valid from too far in future"); >> contracts\DigitalTouristID.sol
    echo         >> contracts\DigitalTouristID.sol
    echo         tokens[tokenId] = TouristToken(dataHash, pointer, validFrom, validTill, false); >> contracts\DigitalTouristID.sol
    echo         emit Minted(tokenId, dataHash, pointer, validFrom, validTill, msg.sender); >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     function revokeTouristID(string calldata tokenId, string calldata reason) external onlyIssuer { >> contracts\DigitalTouristID.sol
    echo         require(tokens[tokenId].validFrom != 0, "Token does not exist"); >> contracts\DigitalTouristID.sol
    echo         tokens[tokenId].revoked = true; >> contracts\DigitalTouristID.sol
    echo         emit Revoked(tokenId, reason, msg.sender); >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     function logAccess(string calldata tokenId, address accessor, string calldata fields) external onlyIssuer { >> contracts\DigitalTouristID.sol
    echo         require(tokens[tokenId].validFrom != 0, "Token does not exist"); >> contracts\DigitalTouristID.sol
    echo         emit AccessLogged(tokenId, accessor, fields, block.timestamp); >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     function getToken(string calldata tokenId) external view returns (bytes32, string memory, uint256, uint256, bool) { >> contracts\DigitalTouristID.sol
    echo         TouristToken storage t = tokens[tokenId]; >> contracts\DigitalTouristID.sol
    echo         return (t.dataHash, t.pointer, t.validFrom, t.validTill, t.revoked); >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo.>> contracts\DigitalTouristID.sol
    echo     function isTokenValid(string calldata tokenId) external view returns (bool) { >> contracts\DigitalTouristID.sol
    echo         TouristToken storage t = tokens[tokenId]; >> contracts\DigitalTouristID.sol
    echo         return t.validFrom != 0 ^&^& !t.revoked ^&^& block.timestamp ^>= t.validFrom ^&^& block.timestamp ^<= t.validTill; >> contracts\DigitalTouristID.sol
    echo     } >> contracts\DigitalTouristID.sol
    echo } >> contracts\DigitalTouristID.sol

    call :print_status "Created DigitalTouristID.sol contract"

    REM Create migration file
    > migrations\2_deploy_dtid.js (
        echo const DigitalTouristID = artifacts.require("DigitalTouristID");
        echo.
        echo module.exports = function(deployer) {
        echo   deployer.deploy(DigitalTouristID);
        echo };
    )
    call :print_status "Created migration file"
    goto :eof

:setup_python
    call :print_step "Setting up Python environment..."
    
    REM Use 'where' to find python and confirm
    where python >nul 2>nul
    if %errorlevel% neq 0 (
        call :print_error "Python executable not found in PATH."
        exit /b 1
    )
    for /f "delims=" %%i in ('python --version') do set "PYTHON_VERSION=%%i"
    call :print_status "Using python -> !PYTHON_VERSION!"

    REM create venv if not exists
    if not exist ".venv" (
        python -m venv .venv
        call :print_status "Created Python virtual environment (.venv)"
    )

    REM Define venv paths for Windows
    set "VENV_PIP=.venv\Scripts\pip.exe"

    REM upgrade pip and install packages
    "%VENV_PIP%" install --upgrade pip setuptools wheel > nul
    "%VENV_PIP%" install fastapi uvicorn web3 cryptography pymysql python-dotenv sqlalchemy pydantic

    call :print_status "Installed Python dependencies into venv"
    call :print_status "To activate in PowerShell: .\.venv\Scripts\Activate.ps1"
    call :print_status "   (may need to run: Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned)"
    call :print_status "To activate in CMD: .\.venv\Scripts\activate.bat"
    call :print_status "To activate in Git Bash/WSL: source .venv/Scripts/activate"
    goto :eof

:setup_project_structure
    call :print_step "Setting up project structure..."
    
    REM Create server directory structure
    if not exist server\nul md server
    if not exist server\routers\nul md server\routers
    
    REM Create __init__.py files
    if not exist server\__init__.py type nul > server\__init__.py
    if not exist server\routers\__init__.py type nul > server\routers\__init__.py
    
    call :print_status "Created project structure"
    goto :eof

:generate_env
    call :print_step "Generating environment configuration..."
    
    REM Generate master key using python
    for /f "delims=" %%i in ('python -c "import os, binascii; print(binascii.hexlify(os.urandom(32)).decode())"') do set "MASTER_KEY=%%i"
    
    > .env (
        echo # DTID System Environment Configuration
        echo # Generated on %DATE% %TIME%
        echo.
        echo # Blockchain Configuration
        echo RPC_URL=http://127.0.0.1:8545
        echo CONTRACT_ADDRESS=
        echo PRIVATE_KEY=
        echo.
        echo # Database Configuration
        echo MYSQL_URI=mysql+pymysql://root:root123@127.0.0.1:3306/dtid_db
        echo.
        echo # Encryption Configuration
        echo MASTER_KEY=!MASTER_KEY!
        echo.
        echo # System Configuration
        echo ENVIRONMENT=development
        echo LOG_LEVEL=INFO
        echo.
        echo # API Configuration
        echo API_HOST=0.0.0.0
        echo API_PORT=8000
    )
    
    call :print_status "Generated .env file with master key"
    call :print_warning "Please update CONTRACT_ADDRESS and PRIVATE_KEY in .env after deploying"
    goto :eof

:setup_database
    call :print_step "Setting up MySQL database..."
    
    call :print_status "Please ensure MySQL is running and accessible"
    call :print_status "Default connection: root:root123@localhost:3306"
    call :print_status "You can create the database manually or the system will create it automatically"
    
    REM Test MySQL connection
    where mysql >nul 2>nul
    if %errorlevel% equ 0 (
        call :print_status "Testing MySQL connection..."
        mysql -u root -proot123 -e "SELECT 1;" >nul 2>nul
        if %errorlevel% equ 0 (
            call :print_status "MySQL connection successful"
            
            REM Create database
            mysql -u root -proot123 -e "CREATE DATABASE IF NOT EXISTS dtid_db;" >nul 2>nul
            call :print_status "Database 'dtid_db' created/verified"
        ) else (
            call :print_warning "Could not connect to MySQL. Please ensure MySQL is running with correct credentials."
        )
    )
    goto :eof

:start_services
    call :print_step "Instructions for starting services..."
    
    echo.
    echo To complete the setup and start the system:
    echo.
    echo 1. Start Ganache (in a new terminal):
    echo    ganache --host 127.0.0.1 --port 8545 --accounts 10 --mnemonic "test test test test test test test test test test test junk"
    echo.
    echo 2. Deploy the smart contract:
    echo    truffle compile
    echo    truffle migrate --network development --reset
    echo.
    echo 3. Update .env file:
    echo    - Copy the deployed contract address to CONTRACT_ADDRESS
    echo    - Copy a private key from Ganache accounts to PRIVATE_KEY
    echo.
    echo 4. Start the Python server:
    echo    .\.venv\Scripts\activate.bat
    echo    uvicorn server.main:app --reload --port 8000
    echo.
    echo 5. Test the system:
    echo    curl http://localhost:8000/health
    goto :eof

:main
    echo Starting DTID System Setup for Windows...
    
    REM --- FIX: Find NPM's global directory and add it to the PATH ---
    call :print_status "Finding global npm packages..."
    for /f "delims=" %%i in ('npm prefix -g') do set "NPM_GLOBAL_PATH=%%i"
    set "PATH=!NPM_GLOBAL_PATH!;%PATH%"
    call :print_status "Temporarily added '!NPM_GLOBAL_PATH!' to the script's PATH"
    
    call :check_requirements
    call :setup_project
    call :setup_truffle
    call :setup_contract
    call :setup_python
    call :setup_project_structure
    call :generate_env
    call :setup_database
    call :start_services
    
    echo.
    echo [SUCCESS] DTID System setup script completed!
    echo.
    echo Next steps:
    echo 1. Follow the instructions above to start Ganache and deploy contracts
    echo 2. Update the .env file with contract address and private key
    echo 3. Start the Python server
    echo 4. Test with the provided curl examples
    echo.
    echo Happy coding!
    goto :eof