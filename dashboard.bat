@echo off
set ROOT=authority-dashboard

echo Creating project structure...

:: Create folders
mkdir %ROOT%
mkdir %ROOT%\public
mkdir %ROOT%\src
mkdir %ROOT%\src\api
mkdir %ROOT%\src\components
mkdir %ROOT%\src\components\auth
mkdir %ROOT%\src\components\layout
mkdir %ROOT%\src\components\map
mkdir %ROOT%\src\components\alerts
mkdir %ROOT%\src\components\analytics
mkdir %ROOT%\src\components\data-access
mkdir %ROOT%\src\components\common
mkdir %ROOT%\src\hooks
mkdir %ROOT%\src\store
mkdir %ROOT%\src\utils
mkdir %ROOT%\src\styles

:: Create empty files
type nul > %ROOT%\public\index.html
type nul > %ROOT%\public\favicon.ico

type nul > %ROOT%\src\api\axios.js
type nul > %ROOT%\src\api\auth.js
type nul > %ROOT%\src\api\tourists.js
type nul > %ROOT%\src\api\alerts.js
type nul > %ROOT%\src\api\tracking.js
type nul > %ROOT%\src\api\entities.js
type nul > %ROOT%\src\api\analytics.js

type nul > %ROOT%\src\components\auth\AuthorityLogin.jsx

type nul > %ROOT%\src\components\layout\Sidebar.jsx
type nul > %ROOT%\src\components\layout\Header.jsx
type nul > %ROOT%\src\components\layout\MainLayout.jsx

type nul > %ROOT%\src\components\map\TacticalMap.jsx
type nul > %ROOT%\src\components\map\MapControls.jsx
type nul > %ROOT%\src\components\map\CustomMarker.jsx
type nul > %ROOT%\src\components\map\Heatmap.jsx

type nul > %ROOT%\src\components\alerts\AlertsList.jsx
type nul > %ROOT%\src\components\alerts\AlertCard.jsx
type nul > %ROOT%\src\components\alerts\SOSPanel.jsx
type nul > %ROOT%\src\components\alerts\DispatchModal.jsx

type nul > %ROOT%\src\components\analytics\SafetyGauge.jsx
type nul > %ROOT%\src\components\analytics\TrendChart.jsx
type nul > %ROOT%\src\components\analytics\StatsWidget.jsx

type nul > %ROOT%\src\components\data-access\BreakGlassPanel.jsx
type nul > %ROOT%\src\components\data-access\AccessLogViewer.jsx

type nul > %ROOT%\src\components\common\Loading.jsx
type nul > %ROOT%\src\components\common\ErrorBoundary.jsx

type nul > %ROOT%\src\hooks\useWebSocket.js
type nul > %ROOT%\src\hooks\useAuth.js
type nul > %ROOT%\src\hooks\useMapControls.js

type nul > %ROOT%\src\store\authStore.js
type nul > %ROOT%\src\store\alertsStore.js
type nul > %ROOT%\src\store\mapStore.js

type nul > %ROOT%\src\utils\constants.js
type nul > %ROOT%\src\utils\formatting.js
type nul > %ROOT%\src\utils\haversine.js

type nul > %ROOT%\src\styles\globals.css

type nul > %ROOT%\src\App.jsx
type nul > %ROOT%\src\main.jsx

type nul > %ROOT%\.env.local
type nul > %ROOT%\.env.example
type nul > %ROOT%\package.json
type nul > %ROOT%\vite.config.js
type nul > %ROOT%\tailwind.config.js
type nul > %ROOT%\README.md

echo Structure created successfully!
pause
