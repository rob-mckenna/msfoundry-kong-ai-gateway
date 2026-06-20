import express from 'express';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import { z } from 'zod';

const DEFAULT_MOCK_API_URL = 'https://kongai-mock-api.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io';
const DEFAULT_PUBLIC_MESSAGES_PATH = '/mcp/messages';
const PORT = Number.parseInt(process.env.PORT ?? '8080', 10);
const MOCK_API_URL = (process.env.MOCK_API_URL ?? DEFAULT_MOCK_API_URL).replace(/\/$/, '');

const app = express();
const transports = new Map();

app.use(express.json());

function log(message, metadata = {}) {
  console.log(
    JSON.stringify({
      timestamp: new Date().toISOString(),
      message,
      ...metadata
    })
  );
}

function formatError(error, fallbackMessage) {
  if (error instanceof Error) {
    return error.message;
  }

  return fallbackMessage;
}

function getPublicMessagesPath(req) {
  const headerValue = req.get('x-external-mcp-messages-path');

  if (!headerValue) {
    return DEFAULT_PUBLIC_MESSAGES_PATH;
  }

  if (!headerValue.startsWith('/')) {
    log('Ignoring invalid public MCP messages path override', {
      headerValue
    });
    return DEFAULT_PUBLIC_MESSAGES_PATH;
  }

  return headerValue;
}

async function callMockApi(path, options = {}) {
  const url = new URL(path, `${MOCK_API_URL}/`);

  log('Calling Mock API', {
    method: options.method ?? 'GET',
    mockApiUrl: url.toString()
  });

  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(options.headers ?? {})
    }
  });

  const bodyText = await response.text();
  let body;

  try {
    body = bodyText ? JSON.parse(bodyText) : null;
  } catch {
    body = bodyText;
  }

  if (!response.ok) {
    const error = new Error(
      `Mock API request failed (${response.status} ${response.statusText})`
    );
    error.statusCode = response.status;
    error.responseBody = body;
    throw error;
  }

  return body;
}

function createServer() {
  const server = new McpServer(
    {
      name: 'mock-api-mcp-server',
      version: '1.0.0'
    },
    {
      capabilities: {
        logging: {}
      }
    }
  );

  server.registerTool(
    'get_weather',
    {
      description: 'Get current weather for a city',
      inputSchema: {
        location: z.string().describe('City name')
      }
    },
    async ({ location }, extra) => {
      try {
        log('Executing MCP tool', { tool: 'get_weather', location, sessionId: extra.sessionId });
        await server.sendLoggingMessage(
          {
            level: 'info',
            data: `Fetching weather for ${location}`
          },
          extra.sessionId
        );

        const result = await callMockApi(`/api/weather?location=${encodeURIComponent(location)}`);

        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(result)
            }
          ],
          structuredContent: result
        };
      } catch (error) {
        log('MCP tool failed', {
          tool: 'get_weather',
          location,
          sessionId: extra.sessionId,
          error: formatError(error, 'Unknown error')
        });

        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({
                error: 'Failed to fetch weather',
                details: error.responseBody ?? formatError(error, 'Unknown error')
              })
            }
          ],
          isError: true
        };
      }
    }
  );

  server.registerTool(
    'calculate',
    {
      description: 'Perform arithmetic calculation',
      inputSchema: {
        operation: z.enum(['add', 'subtract', 'multiply']),
        a: z.number(),
        b: z.number()
      }
    },
    async ({ operation, a, b }, extra) => {
      try {
        log('Executing MCP tool', {
          tool: 'calculate',
          operation,
          a,
          b,
          sessionId: extra.sessionId
        });
        await server.sendLoggingMessage(
          {
            level: 'info',
            data: `Calculating ${operation} for ${a} and ${b}`
          },
          extra.sessionId
        );

        const result = await callMockApi('/api/calculate', {
          method: 'POST',
          body: JSON.stringify({ operation, a, b })
        });

        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(result)
            }
          ],
          structuredContent: result
        };
      } catch (error) {
        log('MCP tool failed', {
          tool: 'calculate',
          operation,
          a,
          b,
          sessionId: extra.sessionId,
          error: formatError(error, 'Unknown error')
        });

        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({
                error: 'Failed to complete calculation',
                details: error.responseBody ?? formatError(error, 'Unknown error')
              })
            }
          ],
          isError: true
        };
      }
    }
  );

  return server;
}

app.get('/health', async (req, res) => {
  try {
    const status = await callMockApi('/api/status');
    res.json({
      status: 'ok',
      mockApiUrl: MOCK_API_URL,
      mockApiStatus: status
    });
  } catch (error) {
    log('Health probe failed', {
      error: formatError(error, 'Unknown error')
    });
    res.status(503).json({
      status: 'degraded',
      mockApiUrl: MOCK_API_URL,
      error: error.responseBody ?? formatError(error, 'Unknown error')
    });
  }
});

app.get('/mcp/sse', async (req, res) => {
  const publicMessagesPath = getPublicMessagesPath(req);

  log('Opening SSE transport', {
    clientIp: req.ip,
    publicMessagesPath
  });

  res.setHeader('X-Accel-Buffering', 'no');

  try {
    const transport = new SSEServerTransport(publicMessagesPath, res);
    const sessionId = transport.sessionId;

    transports.set(sessionId, transport);
    transport.onclose = () => {
      log('Closing SSE transport', { sessionId });
      transports.delete(sessionId);
    };

    const server = createServer();
    await server.connect(transport);

    log('SSE transport established', { sessionId });
  } catch (error) {
    log('Failed to establish SSE transport', {
      error: formatError(error, 'Unknown error')
    });

    if (!res.headersSent) {
      res.status(500).json({ error: 'Failed to establish SSE transport' });
    }
  }
});

app.post('/mcp/messages', async (req, res) => {
  const sessionId = typeof req.query.sessionId === 'string' ? req.query.sessionId : undefined;

  if (!sessionId) {
    res.status(400).json({ error: 'Missing sessionId query parameter' });
    return;
  }

  const transport = transports.get(sessionId);

  if (!transport) {
    res.status(404).json({ error: 'Unknown MCP session' });
    return;
  }

  try {
    await transport.handlePostMessage(req, res, req.body);
  } catch (error) {
    log('Failed to handle MCP message', {
      sessionId,
      error: formatError(error, 'Unknown error')
    });

    if (!res.headersSent) {
      res.status(500).json({ error: 'Failed to handle MCP message' });
    }
  }
});

app.use((req, res) => {
  res.status(404).json({
    error: 'Not found',
    path: req.path
  });
});

app.use((error, req, res, next) => {
  log('Unhandled server error', { error: formatError(error, 'Unknown error') });
  res.status(500).json({
    error: 'Internal server error'
  });
});

const listener = app.listen(PORT, '0.0.0.0', () => {
  log('MCP server listening', {
    port: PORT,
    mockApiUrl: MOCK_API_URL,
    sseEndpoint: '/mcp/sse',
    defaultMessagesEndpoint: DEFAULT_PUBLIC_MESSAGES_PATH,
    messagesPathOverrideHeader: 'x-external-mcp-messages-path',
    healthEndpoint: '/health'
  });
});

listener.requestTimeout = 0;
listener.timeout = 0;

async function shutdown() {
  log('Shutting down MCP server');

  for (const [sessionId, transport] of transports.entries()) {
    try {
      await transport.close();
      transports.delete(sessionId);
    } catch (error) {
      log('Failed to close transport during shutdown', {
        sessionId,
        error: formatError(error, 'Unknown error')
      });
    }
  }

  listener.close(() => {
    process.exit(0);
  });
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
