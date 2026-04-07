/// MCP (Model Context Protocol) 类型定义
/// 基于 JSON-RPC 2.0 协议

enum McpTransportType { stdio, sse, http, ws }

enum McpServerStatus { pending, connected, failed, needsAuth, disabled }

/// MCP 服务器配置
abstract class McpServerConfig {
  const McpServerConfig({required this.name});

  final String name;

  Map<String, Object?> toJson();
}

/// Stdio 传输配置
class McpStdioServerConfig extends McpServerConfig {
  const McpStdioServerConfig({
    required super.name,
    required this.command,
    this.args = const [],
    this.env,
  });

  final String command;
  final List<String> args;
  final Map<String, String>? env;

  @override
  Map<String, Object?> toJson() {
    return {
      'name': name,
      'type': 'stdio',
      'command': command,
      'args': args,
      if (env != null) 'env': env,
    };
  }

  factory McpStdioServerConfig.fromJson(Map<String, Object?> json) {
    return McpStdioServerConfig(
      name: json['name'] as String,
      command: json['command'] as String,
      args: (json['args'] as List?)?.cast<String>() ?? [],
      env: (json['env'] as Map?)?.cast<String, String>(),
    );
  }
}

/// MCP 服务器能力
class McpServerCapabilities {
  const McpServerCapabilities({
    this.tools = false,
    this.resources = false,
    this.prompts = false,
  });

  final bool tools;
  final bool resources;
  final bool prompts;

  factory McpServerCapabilities.fromJson(Map<String, Object?> json) {
    return McpServerCapabilities(
      tools: json['tools'] != null,
      resources: json['resources'] != null,
      prompts: json['prompts'] != null,
    );
  }

  Map<String, Object?> toJson() {
    return {
      if (tools) 'tools': {},
      if (resources) 'resources': {},
      if (prompts) 'prompts': {},
    };
  }
}

/// MCP 服务器信息
class McpServerInfo {
  const McpServerInfo({
    required this.name,
    required this.version,
  });

  final String name;
  final String version;

  factory McpServerInfo.fromJson(Map<String, Object?> json) {
    return McpServerInfo(
      name: json['name'] as String,
      version: json['version'] as String,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'version': version,
    };
  }
}

/// MCP 工具定义
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, Object?>? inputSchema;

  factory McpTool.fromJson(Map<String, Object?> json) {
    return McpTool(
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      inputSchema: json['inputSchema'] as Map<String, Object?>?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      if (inputSchema != null) 'inputSchema': inputSchema,
    };
  }
}

/// MCP 资源定义
class McpResource {
  const McpResource({
    required this.uri,
    required this.name,
    this.description,
    this.mimeType,
  });

  final String uri;
  final String name;
  final String? description;
  final String? mimeType;

  factory McpResource.fromJson(Map<String, Object?> json) {
    return McpResource(
      uri: json['uri'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      mimeType: json['mimeType'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'uri': uri,
      'name': name,
      if (description != null) 'description': description,
      if (mimeType != null) 'mimeType': mimeType,
    };
  }
}

/// MCP 资源内容
class McpResourceContent {
  const McpResourceContent({
    required this.uri,
    required this.mimeType,
    this.text,
    this.blob,
  });

  final String uri;
  final String mimeType;
  final String? text;
  final String? blob; // base64 encoded

  factory McpResourceContent.fromJson(Map<String, Object?> json) {
    return McpResourceContent(
      uri: json['uri'] as String,
      mimeType: json['mimeType'] as String? ?? 'text/plain',
      text: json['text'] as String?,
      blob: json['blob'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'uri': uri,
      'mimeType': mimeType,
      if (text != null) 'text': text,
      if (blob != null) 'blob': blob,
    };
  }
}

/// MCP 连接状态
class McpConnection {
  const McpConnection({
    required this.name,
    required this.status,
    required this.config,
    this.capabilities,
    this.serverInfo,
    this.error,
  });

  final String name;
  final McpServerStatus status;
  final McpServerConfig config;
  final McpServerCapabilities? capabilities;
  final McpServerInfo? serverInfo;
  final String? error;

  McpConnection copyWith({
    String? name,
    McpServerStatus? status,
    McpServerConfig? config,
    McpServerCapabilities? capabilities,
    McpServerInfo? serverInfo,
    String? error,
  }) {
    return McpConnection(
      name: name ?? this.name,
      status: status ?? this.status,
      config: config ?? this.config,
      capabilities: capabilities ?? this.capabilities,
      serverInfo: serverInfo ?? this.serverInfo,
      error: error ?? this.error,
    );
  }
}
