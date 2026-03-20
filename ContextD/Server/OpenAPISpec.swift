import Foundation

/// Static OpenAPI 3.1 specification for the ContextD API.
/// Served at GET /openapi.json.
enum OpenAPISpec {
    static let json = """
    {
      "openapi": "3.1.0",
      "info": {
        "title": "ContextD API",
        "description": "Search and browse your recent screen activity. ContextD continuously captures and summarizes what you see on screen, and this API lets you search summaries, list activity, and retrieve structured data from your captures.",
        "version": "0.1.0",
        "contact": {
          "name": "ContextD"
        },
        "license": {
          "name": "MIT"
        }
      },
      "servers": [
        {
          "url": "http://127.0.0.1:21890",
          "description": "Local ContextD instance"
        }
      ],
      "paths": {
        "/v1/search": {
          "post": {
            "operationId": "searchSummaries",
            "summary": "Full-text search over activity summaries",
            "description": "Search through activity summaries using FTS5 full-text search. This is a fast, local-only operation that does not call any LLM. Returns citations built directly from matching summary records.",
            "requestBody": {
              "required": true,
              "content": {
                "application/json": {
                  "schema": {
                    "$ref": "#/components/schemas/SearchRequest"
                  },
                  "examples": {
                    "simple": {
                      "summary": "Simple search",
                      "value": {
                        "text": "auth token OAuth"
                      }
                    },
                    "with_options": {
                      "summary": "Search with time range and limit",
                      "value": {
                        "text": "docker deployment error",
                        "time_range_minutes": 120,
                        "limit": 5
                      }
                    }
                  }
                }
              }
            },
            "responses": {
              "200": {
                "description": "Search results",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/QueryResponse"
                    }
                  }
                }
              },
              "400": {
                "description": "Invalid request",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/ErrorResponse"
                    }
                  }
                }
              },
              "500": {
                "description": "Internal server error",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/ErrorResponse"
                    }
                  }
                }
              }
            }
          }
        },
        "/v1/summaries": {
          "get": {
            "operationId": "listSummaries",
            "summary": "List activity summaries within a time range",
            "description": "Returns all progressive summaries within the last N minutes, ordered by most recent first. No LLM calls — reads directly from the database.",
            "parameters": [
              {
                "name": "minutes",
                "in": "query",
                "description": "How far back to look, in minutes. Defaults to 60. Maximum 1440.",
                "required": false,
                "schema": {
                  "type": "integer",
                  "default": 60,
                  "minimum": 1,
                  "maximum": 1440
                }
              },
              {
                "name": "limit",
                "in": "query",
                "description": "Maximum number of summaries to return. Defaults to 50. Maximum 200.",
                "required": false,
                "schema": {
                  "type": "integer",
                  "default": 50,
                  "minimum": 1,
                  "maximum": 200
                }
              }
            ],
            "responses": {
              "200": {
                "description": "Summaries retrieved successfully",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/SummariesResponse"
                    }
                  }
                }
              },
              "500": {
                "description": "Internal server error",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/ErrorResponse"
                    }
                  }
                }
              }
            }
          }
        },
        "/v1/activity": {
          "get": {
            "operationId": "listActivity",
            "summary": "Browse activity near a timestamp",
            "description": "Returns a chronological list of activities centered around a timestamp. Use the 'kind' parameter to choose between raw OCR captures or summarized activity.",
            "parameters": [
              {
                "name": "timestamp",
                "in": "query",
                "description": "ISO 8601 timestamp to center the window on. Defaults to now.",
                "required": false,
                "schema": {
                  "type": "string",
                  "format": "date-time"
                },
                "example": "2026-03-12T10:30:00Z"
              },
              {
                "name": "window_minutes",
                "in": "query",
                "description": "Total window size in minutes (centered on timestamp). Defaults to 5. Maximum 1440.",
                "required": false,
                "schema": {
                  "type": "integer",
                  "default": 5,
                  "minimum": 1,
                  "maximum": 1440
                }
              },
              {
                "name": "kind",
                "in": "query",
                "description": "Type of activity to return: 'captures' for raw OCR text, 'summaries' for LLM-generated summaries.",
                "required": false,
                "schema": {
                  "type": "string",
                  "enum": ["captures", "summaries"],
                  "default": "captures"
                }
              },
              {
                "name": "limit",
                "in": "query",
                "description": "Maximum number of results. Defaults to 100. Maximum 500.",
                "required": false,
                "schema": {
                  "type": "integer",
                  "default": 100,
                  "minimum": 1,
                  "maximum": 500
                }
              }
            ],
            "responses": {
              "200": {
                "description": "Activity retrieved successfully",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/ActivityResponse"
                    }
                  }
                }
              },
              "400": {
                "description": "Invalid request",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/ErrorResponse"
                    }
                  }
                }
              },
              "500": {
                "description": "Internal server error",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/ErrorResponse"
                    }
                  }
                }
              }
            }
          }
        },
        "/health": {
          "get": {
            "operationId": "healthCheck",
            "summary": "Health check",
            "description": "Returns the current status of the ContextD API server and basic database statistics.",
            "responses": {
              "200": {
                "description": "Server is healthy",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/HealthResponse"
                    }
                  }
                }
              }
            }
          }
        },
        "/openapi.json": {
          "get": {
            "operationId": "getOpenAPISpec",
            "summary": "OpenAPI specification",
            "description": "Returns this OpenAPI 3.1 specification as JSON.",
            "responses": {
              "200": {
                "description": "OpenAPI spec",
                "content": {
                  "application/json": {
                    "schema": {
                      "type": "object"
                    }
                  }
                }
              }
            }
          }
        }
      },
      "components": {
        "schemas": {
          "SearchRequest": {
            "type": "object",
            "required": ["text"],
            "properties": {
              "text": {
                "type": "string",
                "description": "Search text for FTS5 full-text search over activity summaries.",
                "minLength": 1,
                "examples": ["auth token OAuth"]
              },
              "time_range_minutes": {
                "type": "integer",
                "description": "How far back to search, in minutes. Defaults to 1440 (24 hours). Maximum 1440.",
                "default": 1440,
                "minimum": 1,
                "maximum": 1440
              },
              "limit": {
                "type": "integer",
                "description": "Maximum number of results to return. Defaults to 20. Maximum 100.",
                "default": 20,
                "minimum": 1,
                "maximum": 100
              }
            }
          },
          "QueryResponse": {
            "type": "object",
            "required": ["citations", "metadata"],
            "properties": {
              "citations": {
                "type": "array",
                "description": "Array of citations from the user's recent screen activity, ordered by relevance.",
                "items": {
                  "$ref": "#/components/schemas/Citation"
                }
              },
              "metadata": {
                "$ref": "#/components/schemas/QueryResponseMetadata"
              }
            }
          },
          "Citation": {
            "type": "object",
            "required": ["timestamp", "app_name", "relevant_text", "relevance_explanation", "source"],
            "properties": {
              "timestamp": {
                "type": "string",
                "format": "date-time",
                "description": "ISO 8601 timestamp of the source capture.",
                "examples": ["2026-03-12T10:23:45Z"]
              },
              "app_name": {
                "type": "string",
                "description": "Name of the application that was active.",
                "examples": ["Google Chrome", "VS Code", "Terminal"]
              },
              "window_title": {
                "type": "string",
                "nullable": true,
                "description": "Title of the window that was visible.",
                "examples": ["Pull Request #482 - GitHub"]
              },
              "relevant_text": {
                "type": "string",
                "description": "The specific text or content from the screen that is relevant to the query.",
                "examples": ["Refactored OAuth2 token refresh logic to handle concurrent requests without race conditions"]
              },
              "relevance_explanation": {
                "type": "string",
                "description": "Brief explanation of why this citation is relevant to the query.",
                "examples": ["This PR review discussed the auth token changes the user is asking about"]
              },
              "source": {
                "type": "string",
                "enum": ["capture", "summary"],
                "description": "Whether this citation was derived from a raw capture or a summary."
              }
            }
          },
          "QueryResponseMetadata": {
            "type": "object",
            "required": ["query", "time_range_minutes", "processing_time_ms", "captures_examined", "summaries_searched"],
            "properties": {
              "query": {
                "type": "string",
                "description": "The original query text."
              },
              "time_range_minutes": {
                "type": "integer",
                "description": "The time range that was searched, in minutes."
              },
              "processing_time_ms": {
                "type": "integer",
                "description": "Total processing time in milliseconds."
              },
              "captures_examined": {
                "type": "integer",
                "description": "Number of screen captures examined."
              },
              "summaries_searched": {
                "type": "integer",
                "description": "Number of activity summaries searched."
              }
            }
          },
          "HealthResponse": {
            "type": "object",
            "required": ["status"],
            "properties": {
              "status": {
                "type": "string",
                "description": "Server status.",
                "examples": ["ok"]
              },
              "capture_count": {
                "type": "integer",
                "nullable": true,
                "description": "Total number of screen captures in the database."
              },
              "summary_count": {
                "type": "integer",
                "nullable": true,
                "description": "Total number of activity summaries in the database."
              }
            }
          },
          "SummariesResponse": {
            "type": "object",
            "required": ["summaries", "time_range_minutes", "total"],
            "properties": {
              "summaries": {
                "type": "array",
                "items": {
                  "$ref": "#/components/schemas/SummaryItem"
                }
              },
              "time_range_minutes": {
                "type": "integer",
                "description": "The time range that was searched."
              },
              "total": {
                "type": "integer",
                "description": "Number of summaries returned."
              }
            }
          },
          "SummaryItem": {
            "type": "object",
            "required": ["start_timestamp", "end_timestamp", "app_names", "summary", "key_topics"],
            "properties": {
              "start_timestamp": {
                "type": "string",
                "format": "date-time",
                "description": "Start of the summarized time window."
              },
              "end_timestamp": {
                "type": "string",
                "format": "date-time",
                "description": "End of the summarized time window."
              },
              "app_names": {
                "type": "array",
                "items": { "type": "string" },
                "description": "Applications involved in this activity window."
              },
              "summary": {
                "type": "string",
                "description": "LLM-generated summary of what the user was doing."
              },
              "key_topics": {
                "type": "array",
                "items": { "type": "string" },
                "description": "Key topics and entities extracted from this activity."
              }
            }
          },
          "ActivityResponse": {
            "type": "object",
            "required": ["activities", "center_timestamp", "window_minutes", "kind", "total"],
            "properties": {
              "activities": {
                "type": "array",
                "items": {
                  "$ref": "#/components/schemas/ActivityItem"
                }
              },
              "center_timestamp": {
                "type": "string",
                "format": "date-time",
                "description": "The center timestamp of the query window."
              },
              "window_minutes": {
                "type": "integer",
                "description": "The total window size in minutes."
              },
              "kind": {
                "type": "string",
                "enum": ["captures", "summaries"],
                "description": "The type of activity returned."
              },
              "total": {
                "type": "integer",
                "description": "Number of activities returned."
              }
            }
          },
          "ActivityItem": {
            "type": "object",
            "required": ["timestamp", "app_name", "text", "kind"],
            "properties": {
              "timestamp": {
                "type": "string",
                "format": "date-time",
                "description": "ISO 8601 timestamp of the activity."
              },
              "app_name": {
                "type": "string",
                "description": "Application name."
              },
              "window_title": {
                "type": "string",
                "nullable": true,
                "description": "Window title. Available for captures, null for summaries."
              },
              "text": {
                "type": "string",
                "description": "The content: full OCR text for captures, summary text for summaries."
              },
              "kind": {
                "type": "string",
                "enum": ["capture", "summary"],
                "description": "Whether this is a raw capture or a summary."
              },
              "frame_type": {
                "type": "string",
                "nullable": true,
                "enum": ["keyframe", "delta"],
                "description": "For captures: whether this is a full-screen keyframe or a delta of changes. Null for summaries."
              },
              "change_percentage": {
                "type": "number",
                "nullable": true,
                "description": "For captures: fraction of screen tiles that changed (0.0-1.0). Null for summaries."
              }
            }
          },
          "ErrorResponse": {
            "type": "object",
            "required": ["error"],
            "properties": {
              "error": {
                "type": "string",
                "description": "Error code.",
                "examples": ["invalid_request", "query_error", "configuration_error"]
              },
              "detail": {
                "type": "string",
                "nullable": true,
                "description": "Human-readable error description."
              }
            }
          }
        }
      }
    }
    """
}
