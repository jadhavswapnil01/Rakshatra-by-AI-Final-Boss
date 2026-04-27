// lib/screens/main_page_screens/enhanced_chatbot_screen.dart - COMPLETE REPLACEMENT
import 'dart:async';
import 'dart:convert';
// import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:iconsax/iconsax.dart';
import 'package:tourist_safety/services/network_service.dart';
import 'package:tourist_safety/services/offline_llm_service.dart';
import 'package:tourist_safety/Services/chatbot_service.dart';
import 'package:tourist_safety/screens/model_selection_screen.dart';
import 'package:tourist_safety/utils/app_colors.dart';
import 'package:tourist_safety/utils/theme_manager.dart';
import 'package:tourist_safety/widgets/chat/rich_message_widget.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:tourist_safety/services/api_service.dart';
import 'package:tourist_safety/services/database_service.dart';
import 'package:geocoding/geocoding.dart';
import 'package:tourist_safety/widgets/model_selector_bottom_sheet.dart';
import 'package:tourist_safety/main_screen.dart';
import 'package:tourist_safety/Services/rag_service.dart';
import 'package:tourist_safety/widgets/vector_db_manager_sheet.dart';
import 'dart:math' as math;

class ChatMessage {
  final String id;
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final bool isStreaming;
  final bool isError;
  
  // 🆕 Rich content
  final Map<String, dynamic>? richData;
  final String responseFormat; // 'text', 'rich', 'emergency'

  final String? ragContext;
  final int? ragChunkCount;
  
  ChatMessage({
    String? id,
    required this.text,
    required this.isUser,
    DateTime? timestamp,
    this.isStreaming = false,
    this.isError = false,
    this.richData,
    this.responseFormat = 'text',
    this.ragContext,        
    this.ragChunkCount,     
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
       timestamp = timestamp ?? DateTime.now();
}

class EnhancedChatbotScreen extends StatefulWidget {
  const EnhancedChatbotScreen({super.key});

  @override
  State<EnhancedChatbotScreen> createState() => _EnhancedChatbotScreenState();
}

class _EnhancedChatbotScreenState extends State<EnhancedChatbotScreen>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  
  @override
  bool get wantKeepAlive => true;

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<ChatMessage> _messages = [];
  
  final ChatbotService _chatbotService = ChatbotService();
  final NetworkService _networkService = NetworkService();
  final ApiService _apiService = ApiService();
  final DatabaseService _db = DatabaseService();
  final FocusNode _focusNode = FocusNode();

  bool _isTyping = false;
  bool _isBotReplying = false;
  bool _isModelLoaded = false;
  bool _ragEnabled = false;
  String? _activeVDBCity;

  NetworkStatus _networkStatus = NetworkStatus.unknown;
  LLMModelConfig? _currentModel;

  StreamSubscription<String>? _streamSubscription;
  StreamSubscription<Map<String, dynamic>>? _statusSubscription;
  StreamSubscription<NetworkStatus>? _networkSubscription;
  
  late AnimationController _connectionAnimController;

  @override
void initState() {
  super.initState();
  ThemeManager().addListener(_onThemeChanged);
  WidgetsBinding.instance.addObserver(this);
  _initializeChat();
  _setupAnimations();
  
  // ✅ NEW: Listen for state changes and force UI rebuild
  _statusSubscription = _chatbotService.statusStream.listen((status) {
    if (mounted) {
      debugPrint('📡 [ChatScreen] Status update received');
      debugPrint('   - Offline Ready: ${status['isOfflineReady']}');
      debugPrint('   - Model: ${status['currentModel']?['name']}');
      debugPrint('   - RAG Enabled: ${status['ragEnabled']}'); // ← NEW
      debugPrint('   - Active VDB: ${status['activeVectorDB']}'); // ← NEW
      
      setState(() {
        _isModelLoaded = status['isOfflineReady'] ?? false;
        if (status['currentModel'] != null) {
          _currentModel = LLMModelConfig.fromJson(status['currentModel']);
        } else {
          _currentModel = null;
        }
        // ✅ FIX: Update RAG state from status
        _ragEnabled = status['ragEnabled'] ?? false;
        _activeVDBCity = status['activeVectorDB'];
      });
    }
  });

  _focusNode.addListener(() {
      // Toggle Nav Bar visibility based on focus
      DashboardScreen.isNavBarVisible.value = !_focusNode.hasFocus;
      
      // Force rebuild to update the bottom margin of the input bar
      if (mounted) setState(() {});
    });
    
  // ✅ FIX: Initialize RAG state from service
  _ragEnabled = _chatbotService.isRAGEnabled;
  _activeVDBCity = _chatbotService.ragService.activeKB?.cityName;
  
  // ✅ FIX: Add post-frame callback to verify RAG state
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (mounted) {
      await _refreshRAGState();
    }
  });
}
  void _setupAnimations() {
    _connectionAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    ThemeManager().removeListener(_onThemeChanged);
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _scrollController.dispose();
    _streamSubscription?.cancel();
    _statusSubscription?.cancel();
    _networkSubscription?.cancel();
    _connectionAnimController.dispose();
    _focusNode.dispose();
    
    super.dispose();
  }

@override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Calculate the bottom inset (keyboard height)
    final bottomInset = View.of(context).viewInsets.bottom;
    
    if (bottomInset == 0.0) {
      // Keyboard is CLOSED: Show Nav Bar
      DashboardScreen.isNavBarVisible.value = true;
      
      // ❌ REMOVED: _focusNode.unfocus(); 
      // Removing that line fixes the "keyboard flashing" bug.
    } else {
      // Keyboard is OPEN: Hide Nav Bar
      // This handles cases where FocusNode didn't catch the change (e.g. re-opening)
      DashboardScreen.isNavBarVisible.value = false;
    }
    
    // Update UI to adjust margins
    if (mounted) setState(() {});
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

Future<void> _initializeChat() async {
  try {
    debugPrint('🚀 Initializing chat screen...');
    
    // Initialize chatbot service
    await _chatbotService.initialize();
    
    // Subscribe to network changes
    _networkSubscription = _networkService.statusStream.listen((status) async {
      if (mounted) {
        debugPrint('📶 Network status changed in chat screen: $status');
        
        setState(() {
          _networkStatus = status;
        });
        
        if (status == NetworkStatus.offline) {
          await _checkAndHandleModelStatus();
        }
      }
    });
    
    // Subscribe to chatbot status
    _statusSubscription = _chatbotService.statusStream.listen((status) {
      if (mounted) {
        debugPrint('🤖 Chatbot status: $status');
        
        setState(() {
          _isModelLoaded = status['isOfflineReady'] ?? false;
          if (status['currentModel'] != null) {
            _currentModel = LLMModelConfig.fromJson(status['currentModel']);
          }
          _ragEnabled = status['ragEnabled'] ?? false;
          _activeVDBCity = status['activeVectorDB'];
        });
      }
    });
    
    // Get initial network status
    await _networkService.initialize();
    _networkStatus = _networkService.currentStatus;
    
    debugPrint('📡 Initial network status: $_networkStatus');
    
    if (_networkStatus == NetworkStatus.offline) {
      await _checkAndHandleModelStatus();
    }
    
    // ✅ FIX: Force refresh RAG state from saved data
    await _refreshRAGState();
    
    // ✅ FIX: Check location and suggest KB
    await _checkLocationKB();
    
    // Add welcome messages
    _addWelcomeMessages();
    
    // Setup text controller listener
    _textController.addListener(() {
      if (mounted) setState(() => _isTyping = _textController.text.isNotEmpty);
    });
    
    debugPrint('✅ Chat screen initialized successfully');
    debugPrint('   - RAG Enabled: $_ragEnabled');
    debugPrint('   - Active VDB: $_activeVDBCity');
    
  } catch (e) {
    debugPrint('❌ Chat initialization error: $e');
    _addMessage(ChatMessage(
      text: 'Failed to initialize chat service.',
      isUser: false,
      isError: true,
    ));
  }
}

Future<void> _refreshRAGState() async {
  try {
    debugPrint('🔄 Refreshing RAG state in chat screen...');
    
    // Force chatbot service to refresh RAG state
    await _chatbotService.refreshRAGState();
    
    // Get updated state
    final ragEnabled = _chatbotService.isRAGEnabled;
    final activeKB = _chatbotService.ragService.activeKB;
    
    if (mounted) {
      setState(() {
        _ragEnabled = ragEnabled;
        _activeVDBCity = activeKB?.cityName;
      });
    }
    
    debugPrint('✅ RAG state refreshed in chat screen');
    debugPrint('   - Enabled: $_ragEnabled');
    debugPrint('   - Active KB: $_activeVDBCity');
    
    // ✅ FIX: If RAG is enabled and we have an active KB, verify it's working
    if (_ragEnabled && activeKB != null) {
      final isVerified = await _chatbotService.ragService.verifyActiveVDB();
      if (!isVerified) {
        debugPrint('⚠️ VDB verification failed, disabling RAG');
        await _chatbotService.setRAGEnabled(false);
        if (mounted) {
          setState(() {
            _ragEnabled = false;
          });
        }
        _showSnackBar(
          'Vector database error. Please re-convert the knowledge base.',
          isError: true,
        );
      } else {
        debugPrint('✅ VDB verified and ready');
      }
    }
  } catch (e) {
    debugPrint('❌ RAG state refresh failed: $e');
  }
}

void _showSnackBar(String message, {required bool isError}) {
  if (!mounted) return;
  
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: isError ? AppColors.error : AppColors.success,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: isError ? 4 : 2),
    ),
  );
}


Future<void> _checkLocationKB() async {
  try {
    final kb = await _chatbotService.ragService.checkCurrentLocationKB();
    
    if (kb != null && !kb.isReady && mounted) {
      // Show suggestion to download KB
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Row(
              children: [
                Icon(Iconsax.location, color: AppColors.primary, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Local Knowledge Available',
                    style: TextStyle(color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'We detected you\'re in ${kb.cityName}.',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Would you like to download the local knowledge base for better AI responses about ${kb.cityName}?',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.infoSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.infoBorder),
                  ),
                  child: Row(
                    children: [
                      Icon(Iconsax.info_circle, color: AppColors.infoContent, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Local knowledge helps the AI provide more accurate information about attractions, safety, and local tips.',
                          style: TextStyle(
                            color: AppColors.infoContent,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Not Now'),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  showVectorDBManager(
                    context: context,
                    ragService: _chatbotService.ragService,
                    chatbotService: _chatbotService,
                    onVDBChanged: () {
                      if (mounted) {
                        setState(() {
                          _ragEnabled = _chatbotService.isRAGEnabled;
                          _activeVDBCity = _chatbotService.ragService.activeKB?.cityName;
                        });
                      }
                    },
                  );
                },
                icon: const Icon(Iconsax.document_download, size: 16),
                label: const Text('Download'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        );
      });
    }
  } catch (e) {
    debugPrint('⚠️ Location KB check failed: $e');
  }
}


Future<void> _checkAndHandleModelStatus() async {
  final modelStatus = await _chatbotService.checkModelStatus();
  final action = modelStatus['action'];
  
  debugPrint('📋 Model status check: $modelStatus');
  
  // ✅ FIX: Only show prompts for specific actions
  if (action == 'show_download_prompt') {
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'No offline AI model available. Go to Settings to download one.',
        ),
        backgroundColor: AppColors.warning,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Settings',
          textColor: Colors.white,
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ModelSelectionScreen(),
              ),
            );
          },
        ),
      ),
    );
  } else if (action == 'show_model_picker') {
    if (!mounted) return;
    
    // Navigate to model selection screen instead of showing picker
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ModelSelectionScreen(),
      ),
    ).then((result) {
      if (mounted && result == true) {
        _checkAndHandleModelStatus();
      }
    });
  }
}

// void _showModelLoadPicker(List<LLMModelConfig> models) {
//   Navigator.push(
//     context,
//     MaterialPageRoute(
//       builder: (context) => const ModelSelectionScreen(),
//     ),
//   ).then((result) {
//     // Refresh state after returning from model selection
//     if (mounted && result == true) {
//       setState(() {
//         // Force state refresh
//       });
//       _checkAndHandleModelStatus();
//     }
//   });
// }

  void _addWelcomeMessages() {
    _addMessage(ChatMessage(
      text: "👋 Hello! I'm your AI travel assistant. I can help with attractions, safety, weather, navigation, and emergencies.",
      isUser: false,
    ));
    
    // Show quick actions
    final quickReplies = [
      'Find nearby hospitals',
      'Weather forecast',
      'Safety tips',
      'Tourist attractions',
    ];
    
    _addMessage(ChatMessage(
      text: '',
      isUser: false,
      richData: {'quick_replies': quickReplies},
      responseFormat: 'rich',
    ));
  }

  void _addMessage(ChatMessage message) {
    if (mounted) {
      setState(() {
        _messages.add(message);
      });
      _scrollToBottom();
    }
  }

 void _sendMessage(String text) {
  if (text.trim().isEmpty || _isBotReplying) return;

  final cleanText = text.trim();

  final canUseOffline = _isModelLoaded && _currentModel != null;
  final canUseOnline = _networkStatus == NetworkStatus.online;
  
  debugPrint('📤 [ChatScreen] Send Message Check:');
  debugPrint('  - Network: $_networkStatus');
  debugPrint('  - Model Loaded: $_isModelLoaded');
  debugPrint('  - Current Model: ${_currentModel?.name}');
  debugPrint('  - Can Use Offline: $canUseOffline');
  debugPrint('  - Can Use Online: $canUseOnline');

  if (!canUseOnline && !canUseOffline) {
    debugPrint('❌ [ChatScreen] No AI capability available');
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'No AI available. Please connect to internet or download a model.',
        ),
        backgroundColor: AppColors.error,
        action: SnackBarAction(
          label: 'Settings',
          textColor: Colors.white,
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ModelSelectionScreen(),
              ),
            ).then((result) {
              if (result == true && mounted) {
                _chatbotService.forceRefreshOfflineState();
                setState(() {});
              }
            });
          },
        ),
      ),
    );
    return;
  }

  debugPrint('✅ [ChatScreen] Sending message via ${canUseOffline ? "offline" : "online"} mode');
  
  _addMessage(ChatMessage(text: cleanText, isUser: true));
  setState(() {
    _isBotReplying = true;
  });

  _textController.clear();
  _getResponse(cleanText);
}

Future<void> _getResponse(String userInput) async {
  final streamingMessageIndex = _messages.length;
  
  setState(() {
    _isBotReplying = true;
  });

  try {
    String currentStreamingMessage = '';
    Map<String, dynamic>? richData;
    String responseFormat = 'text';
    Map<String, dynamic>? fullBackendResponse;
    
    // ✅ NEW: Store RAG context for this response
    String? ragContext;
    int? ragChunkCount;
    
    _streamSubscription?.cancel();
    
    final bool useOnline = _chatbotService.currentMode == ChatbotMode.online;
    String currentStatus = useOnline ? 'Thinking...' : 'Processing...';
    
    final streamSource = _chatbotService.generateStreamResponse(
      userInput,
      onStatusUpdate: (status) {
        currentStatus = status;
        if (mounted) setState(() {});
      },
    );

    _streamSubscription = streamSource.listen(
      (chunk) {
        if (!mounted) return;
        
        currentStreamingMessage += chunk; 

        setState(() {
          if (_messages.length > streamingMessageIndex) {
            _messages[streamingMessageIndex] = ChatMessage(
              text: currentStreamingMessage,
              isUser: false,
              isStreaming: true,
            );
          } else {
            _messages.add(ChatMessage(
              text: currentStreamingMessage,
              isUser: false,
              isStreaming: true,
            ));
          }
          _isBotReplying = false; 
        });

        _scrollToBottom();
      },
      onError: (err) {
        if (!mounted) return;
        final errorMessage = _chatbotService.getUserFriendlyError(err);
        setState(() {
          if (_messages.length > streamingMessageIndex) {
             _messages[streamingMessageIndex] = ChatMessage(
               text: errorMessage, 
               isUser: false, 
               isError: true
             );
          } else {
             _messages.add(ChatMessage(
               text: errorMessage, 
               isUser: false, 
               isError: true
             ));
          }
          _isBotReplying = false;
        });
      },
      onDone: () async {
  if (!mounted) return;
  
  // ✅ FIX: Capture RAG context FIRST before it's cleared
  String? ragContext;
  int? ragChunkCount;
  
  if (_chatbotService.lastRetrievedContext != null) {
    ragContext = _chatbotService.lastRetrievedContext;
    ragChunkCount = _chatbotService.lastChunkCount;
    
    debugPrint('📋 RAG Context Captured:');
    debugPrint('   - Length: ${ragContext?.length ?? 0} chars');
    debugPrint('   - Chunks: $ragChunkCount');
    
    // Clear it so next message doesn't show old context
    _chatbotService.lastRetrievedContext = null;
    _chatbotService.lastChunkCount = 0;
  } else {
    debugPrint('ℹ️ No RAG context for this message');
  }
  
  // Fetch rich data if online
  Map<String, dynamic>? richData;
  String responseFormat = 'text';
  
  if (useOnline) {
     try {
        final fullBackendResponse = await _fetchFullBackendResponse(userInput);
        if (fullBackendResponse != null) {
           richData = fullBackendResponse['rich_response'];
           responseFormat = fullBackendResponse['response_format'] ?? 'text';
        }
     } catch (e) { 
       debugPrint('Rich data fetch error: $e'); 
     }
  }
  
  setState(() {
    final finalText = currentStreamingMessage.isEmpty 
        ? "I'm having trouble generating a response." 
        : currentStreamingMessage;
        
    if (_messages.length > streamingMessageIndex) {
      _messages[streamingMessageIndex] = ChatMessage(
        text: finalText,
        isUser: false,
        isStreaming: false,
        richData: richData,
        responseFormat: responseFormat,
        ragContext: ragContext,           // ✅ NOW THIS WILL WORK
        ragChunkCount: ragChunkCount,     // ✅ NOW THIS WILL WORK
      );
    } else {
       _messages.add(ChatMessage(
        text: finalText,
        isUser: false,
        isStreaming: false,
        richData: richData,
        responseFormat: responseFormat,
        ragContext: ragContext,           // ✅ NOW THIS WILL WORK
        ragChunkCount: ragChunkCount,     // ✅ NOW THIS WILL WORK
       ));
    }
    _isBotReplying = false;
  });
  _streamSubscription = null;
},
    );
  } catch (e) {
    if (mounted) {
      setState(() {
        _messages.add(ChatMessage(
          text: 'Error: $e', 
          isUser: false, 
          isError: true
        ));
        _isBotReplying = false;
      });
    }
  }
}

Future<Map<String, dynamic>?> _fetchFullBackendResponse(String userInput) async {
  try {

    final userProfile = await _db.getUserProfile();
    
    // Get current location using geolocator
    Position? position;
    String city = 'Unknown';
    String country = 'Unknown';
    String countryCode = 'UN';

    try {
      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.whileInUse || 
          permission == LocationPermission.always) {
        // Get current position
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high
        );

        // Reverse geocode to get address details
        List<Placemark> placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude
        );

        if (placemarks.isNotEmpty) {
          Placemark place = placemarks[0];
          city = place.locality ?? city;
          country = place.country ?? country; 
          countryCode = place.isoCountryCode ?? countryCode;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Location fetch error: $e');
      // Fall back to IP-based location or default values
    }
    
    final requestData = {
      'message': userInput,
      'user_profile': {
        'user_id': userProfile?.id ?? 'anonymous-${DateTime.now().millisecondsSinceEpoch}',
        'name': userProfile?.fullName ?? 'Guest User',
        'location': {
          'latitude': position?.latitude ?? 0.0,
          'longitude': position?.longitude ?? 0.0,
          'city': city,
          'country': country,
          'country_code': countryCode,
        },
        'itinerary': [],
        'emergency_contacts': [],
        'health_problems': [],
        'language_preference': 'en',
      },
      'conversation_id': null,
      'context': {},
    };

    final headers = await _apiService.getHeaders(includeAuth: true);
    final response = await http.post(
      Uri.parse('${_apiService.baseUrl}/api/chatbot/chat'),
      headers: headers,
      body: json.encode(requestData),
    ).timeout(
      const Duration(seconds: 30),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    
    return null;
  } catch (e) {
    debugPrint('❌ [Chat] Backend fetch error: $e');
    return null;
  }
}

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }
// inside _EnhancedChatbotScreenState

@override
Widget build(BuildContext context) {
  super.build(context);

  return Scaffold(
    backgroundColor: AppColors.background,
    body: SafeArea(
      child: Stack(
        children: [
          // 1. Main Chat Layout
          Positioned.fill(
            child: Column(
              children: [
                Expanded(child: _buildMessagesList()),
                const SizedBox(height: 80),
              ],
            ),
          ),

          // 2. Floating Header
          Positioned(
            top: 0, left: 0, right: 0,
            child: Column(
              children: [
                _buildFloatingHeader(),
                if (_networkStatus != NetworkStatus.unknown) _buildStatusBanner(),
              ],
            ),
          ),

          // ✅ REMOVED: Global debug overlay (now per-message)

          // 3. Input Bar
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: _buildInputBar(),
          ),
        ],
      ),
    ),
  );
}

Widget _buildFloatingHeader() {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface, 
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: AppColors.border.withOpacity(0.5),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowDark,
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Icon Badge
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Iconsax.message_text_1, color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          
          // Title and Status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'AI Assistant',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _buildStatusText(),
                  style: TextStyle(
                    color: AppColors.textSecondary.withOpacity(0.8),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // ✅ NEW: RAG Toggle Button
          if (_chatbotService.ragService.isInitialized)
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(50),
                onTap: () async {
                  // Show vector DB manager
                  showVectorDBManager(
                    context: context,
                    ragService: _chatbotService.ragService,
                    chatbotService: _chatbotService,
                    onVDBChanged: () {
                      if (mounted) {
                        setState(() {
                          _ragEnabled = _chatbotService.isRAGEnabled;
                          _activeVDBCity = _chatbotService.ragService.activeKB?.cityName;
                        });
                      }
                    },
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        Iconsax.book,
                        color: _ragEnabled ? AppColors.success : AppColors.textSecondary,
                        size: 22,
                      ),
                      if (_ragEnabled && _activeVDBCity != null)
                        Positioned(
                          right: -4,
                          top: -4,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: AppColors.success,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.surface,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          
          // Model Selector
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(50),
              onTap: () {
                showModelSelector(
                  context: context,
                  chatbotService: _chatbotService,
                  onModelChanged: () {
                    if (mounted) setState(() {});
                  },
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Icon(
                  _isModelLoaded ? Iconsax.cpu : Iconsax.cpu_charge,
                  color: _isModelLoaded ? AppColors.primary : AppColors.textSecondary,
                  size: 22,
                ),
              ),
            ),
          ),
          
          // Settings
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(50),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const ModelSelectionScreen()),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Icon(Iconsax.setting_2, color: AppColors.textSecondary, size: 22),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}


Widget _buildRAGIndicator() {
  if (!_ragEnabled || _activeVDBCity == null) {
    return const SizedBox.shrink();
  }

  return Container(
    margin: const EdgeInsets.only(left: 16, right: 16, bottom: 8, top: 4),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [
          AppColors.success.withValues(alpha: 0.15),
          AppColors.success.withValues(alpha: 0.05),
        ],
      ),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: AppColors.success.withValues(alpha: 0.4),
        width: 1.5,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.success.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Iconsax.book,
            color: AppColors.success,
            size: 14,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Using $_activeVDBCity knowledge base',
            style: TextStyle(
              color: AppColors.success,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // ✅ NEW: Status indicator
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AppColors.success,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.success.withValues(alpha: 0.5),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

  String _buildStatusText() {
  if (_networkStatus == NetworkStatus.online) {
    if (_isModelLoaded) {
      return 'Hybrid Mode • Cloud + ${_currentModel?.name ?? "Offline"}';
    }
    return 'Online Mode • Cloud AI';
  } else if (_networkStatus == NetworkStatus.offline) {
    if (_isModelLoaded) {
      return 'Offline • ${_currentModel?.name ?? "Local AI"}';
    }
    return 'Offline • No AI Model';
  }
  return 'Connecting...';
}

 Widget _buildStatusBanner() {
  // ✅ CRITICAL FIX: Only show banner when action is truly needed
  
  // Case 1: Offline with no model - SHOW BANNER
  if (_networkStatus == NetworkStatus.offline && !_isModelLoaded) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.warning.withValues(alpha:0.15),
            AppColors.warning.withValues(alpha:0.05),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppColors.warning.withValues(alpha:0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha:0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Iconsax.wifi_square,
              color: AppColors.warning,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You\'re Offline',
                  style: TextStyle(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Download an offline AI model to continue chatting',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ModelSelectionScreen(),
                ),
              ).then((result) {
                // ✅ FIX: Force refresh after returning
                if (result == true && mounted) {
                  _chatbotService.forceRefreshOfflineState();
                  setState(() {}); // Force UI rebuild
                }
              });
            },
            style: TextButton.styleFrom(
              backgroundColor: AppColors.warning.withValues(alpha:0.15),
              foregroundColor: AppColors.warning,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Settings',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  // Case 2: Offline with model - SHOW SUCCESS BANNER
  if (_networkStatus == NetworkStatus.offline && _isModelLoaded) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.success.withValues(alpha:0.15),
            AppColors.success.withValues(alpha:0.05),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppColors.success.withValues(alpha:0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Iconsax.tick_circle,
            color: AppColors.success,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline mode • ${_currentModel?.name ?? "AI Model"} ready',
              style: TextStyle(
                color: AppColors.success,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  // Case 3: Online - NO BANNER (don't nag user)
  return const SizedBox.shrink();
}

Widget _buildThinkingBlock(String content) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.infoSurface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: AppColors.infoBorder,
        width: 1,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Iconsax.cpu,
              color: AppColors.infoContent,
              size: 16,
            ),
            const SizedBox(width: 6),
            Text(
              'AI Thinking Process',
              style: TextStyle(
                color: AppColors.infoContent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          content,
          style: TextStyle(
            color: AppColors.textPrimary.withOpacity(0.8),
            fontSize: 13,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    ),
  );
}

Widget _buildMessagesList() {
  if (_ragEnabled && _activeVDBCity != null) {
  _buildRAGIndicator();
  };
    return GestureDetector(
      onTap: () {
        if (_focusNode.hasFocus) {
          _focusNode.unfocus();
          DashboardScreen.isNavBarVisible.value = true;
        }
      },
      
      child: ListView.builder(
        controller: _scrollController,
        // UPDATE PADDING HERE: Top padding ensures it starts below header
        padding: const EdgeInsets.fromLTRB(16, 110, 16, 120), 
        itemCount: _messages.length + (_isBotReplying ? 1 : 0),
        itemBuilder: (context, index) {
          // ... existing code ...
          if (index == _messages.length) {
            return _buildEnhancedTypingIndicator();
          }
          
          final message = _messages[index];
          
          if (message.isStreaming && message.text.isEmpty) {
            return const SizedBox.shrink();
          }
          
          return RichMessageWidget(
            message: message,
            onQuickReply: _sendMessage,
            onLocationTap: _handleLocationTap,
            onActionButton: _handleActionButton,
          );
        },
      ),
    );
  }

// ✅ NEW: Enhanced typing indicator with mode display
Widget _buildEnhancedTypingIndicator() {
  // ✅ Get dynamic status from chatbot service
  String statusText = 'Thinking...';
  IconData statusIcon = Iconsax.cpu;
  Color statusColor = AppColors.primary;
  
  if (_ragEnabled && _activeVDBCity != null) {
    statusText = 'Finding context...';
    statusIcon = Iconsax.search_normal;
    statusColor = AppColors.success;
  } else if (_networkStatus == NetworkStatus.offline) {
    statusText = 'Processing...';
    statusIcon = Iconsax.cpu_setting;
    statusColor = AppColors.warning;
  }
  
  return Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(bottom: 12, left: 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomRight: Radius.circular(16),
          bottomLeft: Radius.circular(4),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(color: AppColors.border.withOpacity(0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ✅ Status-aware icon
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(statusIcon, color: statusColor, size: 16),
          ),
          const SizedBox(width: 8),
          _AnimatedTypingDots(),
          const SizedBox(width: 8),
          Text(
            statusText,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    ),
  );
}

  void _handleLocationTap(Map<String, dynamic> locationData) async {
    final lat = locationData['latitude'];
    final lon = locationData['longitude'];
    final name = locationData['name'];
    
    final query = Uri.encodeComponent('$lat,$lon ($name)');
final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$query');
    
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _handleActionButton(Map<String, dynamic> actionData) {
    final actionType = actionData['action_type'];
    
    switch (actionType) {
      case 'sos':
        // Trigger SOS
        break;
      case 'navigate':
        _handleLocationTap(actionData['action_data']);
        break;
      case 'call':
        final phone = actionData['action_data']['phone'];
        launchUrl(Uri.parse('tel:$phone'));
        break;
    }
  }

Widget _buildInputBar() {
    // UPDATED LOGIC 👇
    // If Nav Bar is hidden, we are in "Keyboard Mode" -> margin 16
    // If Nav Bar is visible, we are in "View Mode" -> margin 100
    final double bottomMargin = !DashboardScreen.isNavBarVisible.value ? 16 : 100;

    return Container(
      margin: EdgeInsets.fromLTRB(16, 8, 16, bottomMargin),
      decoration: BoxDecoration(
        color: AppColors.surface, 
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: AppColors.border.withOpacity(0.5),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadowDark,
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              // ADD FOCUS NODE 👇
              focusNode: _focusNode,
              enabled: !_isBotReplying,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Ask about travel, safety, attractions...',
                hintStyle: TextStyle(
                  color: AppColors.textHint,
                  fontSize: 15,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
              ),
              style:  TextStyle(fontSize: 15, height: 1.4, color: AppColors.textPrimary),
              onSubmitted: _sendMessage,
            ),
          ),
          const SizedBox(width: 8),
          _buildSendButton(),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
  
  Widget _buildSendButton() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: _isTyping
          ? GestureDetector(
              key: const ValueKey('send'),
              onTap: (_isTyping && !_isBotReplying)
                  ? () => _sendMessage(_textController.text)
                  : null,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primary, AppColors.primary.withValues(alpha:0.8)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha:0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(Iconsax.send_1, color: Colors.white, size: 20),
              ),
            )
          : Container(
              key: const ValueKey('mic'),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.textSecondary.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(
                Iconsax.microphone_2,
                color: AppColors.textSecondary,
                size: 20,
              ),
            ),
    );
  }
}

class _AnimatedTypingDots extends StatefulWidget {
  @override
  State<_AnimatedTypingDots> createState() => _AnimatedTypingDotsState();
}

class _AnimatedTypingDotsState extends State<_AnimatedTypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final delay = index * 0.3;
            final value = (_controller.value - delay) % 1.0;
            final opacity = value < 0.5 ? value * 2 : (1.0 - value) * 2;
            
            return Container(
              margin: EdgeInsets.only(right: index < 2 ? 4 : 0),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha:opacity.clamp(0.3, 1.0)),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}


class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with TickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.success.withValues(alpha:0.2),
                  AppColors.success.withValues(alpha:0.1),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(Iconsax.mobile_programming, color: AppColors.success, size: 18),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border.withValues(alpha:0.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Thinking",
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 15,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      String dots = '';
                      int dotCount = ((_controller.value * 4) % 4).floor();
                      for (int i = 0; i < dotCount; i++) {
                        dots += '.';
                      }
                      return Text(
                        dots,
                        style:  TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}