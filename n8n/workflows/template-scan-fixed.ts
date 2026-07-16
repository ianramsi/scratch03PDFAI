import { workflow, node, trigger, ifElse } from '@n8n/workflow-sdk';

// ── Trigger ───────────────────────────────────────────────────────────
const webhookTrigger = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2,
  config: {
    name: 'Webhook — /template-scan',
    parameters: { httpMethod: 'POST', path: 'template-scan', responseMode: 'responseNode', options: { rawBody: true } },
    position: [-544, 240],
    webhookId: 'd2058c37-8c1b-4148-8dbf-c4f572adb31e'
  },
  output: [{ headers: { authorization: 'Basic ...' }, body: {} }]
});

// ── Node 2: Check API Key ─────────────────────────────────────────────
const checkApiKey = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Check API Key',
    position: [-352, 240],
    parameters: {
      jsCode:
        "const authHeader = $input.first().json.headers['authorization'] || '';\n" +
        "const expectedUser = 'n3n';\n" +
        "const expectedPass = 'Kampret#1.';\n" +
        "if (!authHeader || !authHeader.toLowerCase().startsWith('basic ')) return { valid: false, error: 'Missing Basic Authorization header.' };\n" +
        "try {\n" +
        "  const base64 = authHeader.substring(6).trim();\n" +
        "  const decoded = Buffer.from(base64, 'base64').toString('utf-8');\n" +
        "  const colonIndex = decoded.indexOf(':');\n" +
        "  if (colonIndex === -1) return { valid: false, error: 'Invalid Basic auth format.' };\n" +
        "  const user = decoded.substring(0, colonIndex);\n" +
        "  const pass = decoded.substring(colonIndex + 1);\n" +
        "  if (user !== expectedUser || pass !== expectedPass) return { valid: false, error: 'Invalid username or password.' };\n" +
        "  return { valid: true };\n" +
        "} catch (e) { return { valid: false, error: 'Failed to decode auth header: ' + e.message }; }"
    }
  },
  output: [{ valid: true }]
});

// ── Node 3: Auth OK? ──────────────────────────────────────────────────
const authOk = ifElse({
  version: 2.2,
  config: {
    name: 'Auth OK?',
    position: [-144, 240],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 1 },
        conditions: [{ id: 'cond-auth-1', leftValue: '={{ $json.valid }}', rightValue: true, operator: { type: 'boolean', operation: 'equals' } }],
        combinator: 'and'
      },
      options: {}
    }
  }
});

// ── Node 21: Respond 401 ──────────────────────────────────────────────
const respond401 = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1,
  config: {
    name: 'Respond 401',
    position: [-48, -16],
    parameters: { respondWith: 'json', responseBody: '={"status":"error","error":"Unauthorized"}', options: {} }
  },
  output: [{}]
});

// ── Node 5: Validate Request Body ─────────────────────────────────────
// jobId UUID check removed: Salesforce sends scan_ prefixed correlation ids.
const validateBody = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Validate Request Body',
    position: [-352, 544],
    parameters: {
      jsCode:
        "const body = $('Webhook — /template-scan').first().json.body;\n" +
        "const required = ['templateId','fileContentVersionId','fileMimeType','fileBase64','callbackUrl','jobId'];\n" +
        "for (const f of required) {\n" +
        "  if (!body[f] || typeof body[f] !== 'string' || body[f].trim() === '') return { valid: false, error: `Missing or empty required field: ${f}` };\n" +
        "}\n" +
        "const mime = body.fileMimeType;\n" +
        'if (mime !== \'application/pdf\' && !mime.startsWith(\'image/\')) return { valid: false, error: `Invalid fileMimeType "${mime}"` };\n' +
        "return { valid: true, jobId: body.jobId, templateId: body.templateId, fileContentVersionId: body.fileContentVersionId, fileMimeType: body.fileMimeType, fileBase64: body.fileBase64, callbackUrl: body.callbackUrl };"
    }
  },
  output: [{ valid: true, jobId: 'a1b2c3d4', templateId: 'a0B...', fileContentVersionId: '068...', fileMimeType: 'application/pdf', fileBase64: '...', callbackUrl: 'https://...' }]
});

// ── Node 6: Body OK? ──────────────────────────────────────────────────
const bodyOk = ifElse({
  version: 2.2,
  config: {
    name: 'Body OK?',
    position: [-144, 544],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ id: 'cond-body-1', leftValue: '={{ $json.valid }}', rightValue: true, operator: { type: 'boolean', operation: 'equals' } }],
        combinator: 'and'
      },
      options: {}
    }
  }
});

// ── Node 7: Respond 400 ───────────────────────────────────────────────
const respond400 = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1,
  config: {
    name: 'Respond 400',
    position: [64, 640],
    parameters: { respondWith: 'json', responseBody: '={"status":"error","error":"{{ $json.error }}"}', options: {} }
  },
  output: [{}]
});

// ── Node 8: Send ACK (200) ────────────────────────────────────────────
const sendAck = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1,
  config: {
    name: 'Send ACK (200)',
    position: [64, 240],
    parameters: { respondWith: 'json', responseBody: '={"status":"accepted","jobId":"{{ $("Validate Request Body").first().json.jobId }}"}', options: {} }
  },
  output: [{}]
});

// ── Node 9: Build Claude Request ──────────────────────────────────────
// System prompt now carries the full schema contract so Claude returns the
// exact shape the validator expects (section.id, rows, fields, type, etc.).
const buildClaudeReq = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Claude Request',
    position: [256, -16],
    parameters: {
      jsCode:
        "const prev = $('Validate Request Body').first().json;\n" +
        "const SYSTEM_PROMPT = [\n" +
        "  'You are a form template analyzer. Extract the structure of the form in the supplied document or image',\n" +
        "  'and output a SINGLE valid JSON object only. No preamble, no markdown fences, no explanation.',\n" +
        "  '',\n" +
        "  'OUTPUT SHAPE:',\n" +
        "  '{ \"schemaVersion\": 1, \"sections\": [ { \"id\": \"<unique>\", \"title\": \"<optional>\", \"rows\": [ { \"id\": \"<unique>\", \"fields\": [ ... ] } ] } ] }',\n" +
        "  '',\n" +
        "  'SCHEMA CONTRACT:',\n" +
        "  '- Every section MUST have a unique string \"id\" and a \"rows\" array.',\n" +
        "  '- Every row MUST have a unique string \"id\" and a \"fields\" array.',\n" +
        "  '- Every field MUST have a unique string \"id\" and a \"type\".',\n" +
        "  '- Field types: text, textarea, number, date, time, checkbox, picklist, table, signature',\n" +
        "  '- colSpan: 1-12 per field; sum per row must be <= 12',\n" +
        "  '- type \"html\" is FORBIDDEN',\n" +
        "  '- signature fields require signerRole: \"engineer\" | \"supervisor\"',\n" +
        "  '- picklist fields require a non-empty \"options\" array of strings',\n" +
        "  '- table fields require a non-empty \"columns\" array; each column has { id (unique), label, type }',\n" +
        "  '- table column \"type\" must be one of: text, number, date, time, checkbox, picklist (signature NOT allowed in tables)',\n" +
        "  '- All section, row, and field \"id\" values must be unique within their scope (field ids unique across the entire schema).',\n" +
        "  '',\n" +
        "  'Output ONLY the JSON object.'\n" +
        "].join('\\n');\n" +
        "const isPdf = prev.fileMimeType === 'application/pdf';\n" +
        "const content = [];\n" +
        "if (isPdf) {\n" +
        "  content.push({ type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: prev.fileBase64 } });\n" +
        "} else {\n" +
        "  content.push({ type: 'image', source: { type: 'base64', media_type: prev.fileMimeType, data: prev.fileBase64 } });\n" +
        "}\n" +
        "content.push({ type: 'text', text: 'Extract the form schema. Output ONLY the JSON.' });\n" +
        "return {\n" +
        "  model: 'claude-sonnet-4-5',\n" +
        "  max_tokens: 4096,\n" +
        "  temperature: 0.1,\n" +
        "  system: SYSTEM_PROMPT,\n" +
        "  messages: [{ role: 'user', content }],\n" +
        "  _jobId: prev.jobId,\n" +
        "  _templateId: prev.templateId,\n" +
        "  _callbackUrl: prev.callbackUrl\n" +
        "};"
    }
  },
  output: [{ model: 'claude-sonnet-4-5', max_tokens: 4096, temperature: 0.1, _jobId: 'a1b2c3d4', _templateId: 'a0B...', _callbackUrl: 'https://...' }]
});

// ── Node 10: Strip Carry Fields ───────────────────────────────────────
const stripCarry = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Strip Carry Fields',
    position: [464, 32],
    parameters: {
      jsCode:
        "const input = $input.first().json;\n" +
        "const claudePayload = {};\n" +
        "for (const [k, v] of Object.entries(input)) {\n" +
        "  if (!k.startsWith('_')) claudePayload[k] = v;\n" +
        "}\n" +
        "return { claudePayload, _jobId: input._jobId, _templateId: input._templateId, _callbackUrl: input._callbackUrl };"
    }
  },
  output: [{ claudePayload: {}, _jobId: 'a1b2c3d4', _templateId: 'a0B...', _callbackUrl: 'https://...' }]
});

// ── Node 11: Call Claude Vision ───────────────────────────────────────
// ANTHROPIC KEY: read from n8n env var `ANTHROPIC_API_KEY`.
// Set in n8n: Settings → Environment Variables.
const callClaude = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4,
  config: {
    name: 'Call Claude Vision',
    position: [464, 240],
    parameters: {
      method: 'POST',
      url: 'https://api.anthropic.com/v1/messages',
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'x-api-key', value: '={{ $env.ANTHROPIC_API_KEY }}' },
          { name: 'anthropic-version', value: '2023-06-01' },
          { name: 'content-type', value: 'application/json' }
        ]
      },
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify($json.claudePayload) }}',
      options: { response: { response: { responseFormat: 'json' } }, timeout: 120000 }
    }
  },
  output: [{ content: [{ type: 'text', text: '{"sections":[]}' }] }]
});

// ── Node 12: Parse & Validate Schema ──────────────────────────────────
const parseValidateSchema = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Parse & Validate Schema',
    position: [656, 240],
    parameters: {
      jsCode:
        "const claudeRes = $input.first().json;\n" +
        "const carry = $('Strip Carry Fields').first().json;\n" +
        "const text = (claudeRes.content || []).filter(c => c.type === 'text').map(c => c.text).join('\\n');\n" +
        "if (!text || text.trim() === '') return { valid: false, error: 'Claude returned empty response.', _jobId: carry._jobId, _templateId: carry._templateId, _callbackUrl: carry._callbackUrl };\n" +
        "let cleaned = text.trim();\n" +
        "if (cleaned.startsWith('```')) cleaned = cleaned.replace(/^```(?:json)?\\s*\\n?/, '').replace(/\\n?```\\s*$/, '');\n" +
        "let schema;\n" +
        "try { schema = JSON.parse(cleaned); } catch (e) { return { valid: false, error: 'Not parseable JSON: ' + e.message, _jobId: carry._jobId, _templateId: carry._templateId, _callbackUrl: carry._callbackUrl }; }\n" +
        "const ALLOWED_TYPES = new Set(['text','textarea','number','date','time','checkbox','picklist','table','signature']);\n" +
        "const errors = []; const seenFieldIds = new Set();\n" +
        "if (!schema.sections || !Array.isArray(schema.sections)) { errors.push('Missing sections array.'); }\n" +
        "else {\n" +
        "  for (const section of schema.sections) {\n" +
        "    if (!section.id) { errors.push('Section missing id.'); continue; }\n" +
        "    if (!section.rows) { errors.push(`Section \"${section.id}\" missing rows.`); continue; }\n" +
        "    for (const row of section.rows) {\n" +
        "      if (!row.id) errors.push('Row missing id.');\n" +
        "      if (!row.fields) { errors.push('Row missing fields.'); continue; }\n" +
        "      let colSum = 0;\n" +
        "      for (const field of row.fields) {\n" +
        "        if (!field.id) { errors.push('Field missing id.'); continue; }\n" +
        "        if (seenFieldIds.has(field.id)) errors.push(`Duplicate field id: ${field.id}`);\n" +
        "        seenFieldIds.add(field.id);\n" +
        "        if (!ALLOWED_TYPES.has(field.type)) errors.push(`Field \"${field.id}\" disallowed type.`);\n" +
        "        colSum += (field.colSpan || 0);\n" +
        "        if (field.type === 'picklist' && (!field.options || !field.options.length)) errors.push(`Picklist \"${field.id}\" needs options.`);\n" +
        "        if (field.type === 'signature' && !['engineer','supervisor'].includes(field.signerRole)) errors.push(`Signature \"${field.id}\" needs signerRole.`);\n" +
        "        if (field.type === 'table' && (!field.columns || !field.columns.length)) errors.push(`Table \"${field.id}\" needs columns.`);\n" +
        "      }\n" +
        "      if (colSum > 12) errors.push(`Row colSpan sum ${colSum} exceeds 12.`);\n" +
        "    }\n" +
        "  }\n" +
        "}\n" +
        "if (seenFieldIds.size === 0) errors.push('Schema contains no fields.');\n" +
        "if (errors.length > 0) return { valid: false, error: errors.join(' | '), _jobId: carry._jobId, _templateId: carry._templateId, _callbackUrl: carry._callbackUrl };\n" +
        "return { valid: true, schema, _jobId: carry._jobId, _templateId: carry._templateId, _callbackUrl: carry._callbackUrl };"
    }
  },
  output: [{ valid: true, schema: { sections: [] }, _jobId: 'a1b2c3d4', _templateId: 'a0B...', _callbackUrl: 'https://...' }]
});

// ── Node 13: Schema Valid? ────────────────────────────────────────────
const schemaValid = ifElse({
  version: 2.2,
  config: {
    name: 'Schema Valid?',
    position: [864, 240],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ id: 'cond-schema-1', leftValue: '={{ $json.valid }}', rightValue: true, operator: { type: 'boolean', operation: 'equals' } }],
        combinator: 'and'
      },
      options: {}
    }
  }
});

// ── Node 14: Build Success Payload ────────────────────────────────────
const buildSuccessPayload = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Success Payload',
    position: [1056, 80],
    parameters: {
      jsCode:
        "const item = $input.first().json;\n" +
        "return { _jobId: item._jobId, _templateId: item._templateId, _callbackUrl: item._callbackUrl, _payload: JSON.stringify({ jobId: item._jobId, templateId: item._templateId, status: 'success', schema: item.schema }) };"
    }
  },
  output: [{ _jobId: 'a1b2c3d4', _templateId: 'a0B...', _callbackUrl: 'https://...', _payload: '{}' }]
});

// ── Node 15: Build Error Payload ──────────────────────────────────────
const buildErrorPayload = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Error Payload',
    position: [1056, 384],
    parameters: {
      jsCode:
        "const item = $input.first().json;\n" +
        "return { _jobId: item._jobId, _templateId: item._templateId, _callbackUrl: item._callbackUrl, _payload: JSON.stringify({ jobId: item._jobId, templateId: item._templateId, status: 'error', error: item.error || 'Unknown scan error.' }) };"
    }
  },
  output: [{ _jobId: 'a1b2c3d4', _templateId: 'a0B...', _callbackUrl: 'https://...', _payload: '{}' }]
});

// ── Node 16: Merge Payloads ───────────────────────────────────────────
const mergePayloads = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Merge Payloads',
    position: [1264, 80],
    parameters: { jsCode: "return $input.first().json;" }
  },
  output: [{ _jobId: 'a1b2c3d4', _templateId: 'a0B...', _callbackUrl: 'https://...', _payload: '{}' }]
});

// ── Node 17: Get SF OAuth Token ───────────────────────────────────────
const getSfToken = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4,
  config: {
    name: 'Get SF OAuth Token',
    position: [1264, 240],
    parameters: {
      method: 'POST',
      // Sandbox token URL — works for any sandbox org (including devlks).
      // Updated 2026-07-16: switched from old scratch03 org to new devlks sandbox.
      // All secrets read from n8n env vars (Settings → Environment Variables).
      url: '={{ $env.SF_TOKEN_URL }}',
      sendBody: true,
      contentType: 'form-urlencoded',
      bodyParameters: {
        parameters: [
          { name: 'grant_type', value: 'client_credentials' },
          { name: 'client_id', value: '={{ $env.SF_CLIENT_ID }}' },
          { name: 'client_secret', value: '={{ $env.SF_CLIENT_SECRET }}' }
        ]
      },
      options: { response: { response: { responseFormat: 'json' } }, timeout: 30000 }
    }
  },
  output: [{ access_token: '...' }]
});

// ── Node 18: OAuth OK? ────────────────────────────────────────────────
// Boolean check on access_token (string isNotEmpty op was invalid and always false).
const oauthOk = ifElse({
  version: 2.2,
  config: {
    name: 'OAuth OK?',
    position: [1456, 240],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ id: 'cond-oauth-1', leftValue: '={{ !!$json.access_token }}', rightValue: true, operator: { type: 'boolean', operation: 'equals' } }],
        combinator: 'and'
      },
      options: {}
    }
  }
});

// ── Node 19: POST Callback to SF ──────────────────────────────────────
const postCallback = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4,
  config: {
    name: 'POST Callback to SF',
    position: [1664, 80],
    parameters: {
      method: 'POST',
      url: "={{ $('Merge Payloads').first().json._callbackUrl }}",
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'Authorization', value: "=Bearer {{ $('Get SF OAuth Token').first().json.access_token }}" },
          { name: 'Content-Type', value: 'application/json' }
        ]
      },
      sendBody: true,
      specifyBody: 'json',
      jsonBody: "={{ $('Merge Payloads').first().json._payload }}",
      options: { response: { response: { responseFormat: 'json' } }, timeout: 30000 }
    }
  },
  output: [{ ok: true }]
});

// ── Node 20: Log Completion ───────────────────────────────────────────
const logCompletion = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Log Completion',
    position: [1856, 80],
    parameters: {
      jsCode:
        "const callbackRes = $input.first().json;\n" +
        "const jobId = $('Validate Request Body').first().json.jobId;\n" +
        "const templateId = $('Validate Request Body').first().json.templateId;\n" +
        "const log = { level: 'INFO', jobId, templateId, message: 'Callback delivered successfully.' };\n" +
        "console.log(JSON.stringify(log));\n" +
        "return log;"
    }
  },
  output: [{ level: 'INFO', jobId: 'a1b2c3d4', templateId: 'a0B...' }]
});

// ── Node 22: Log OAuth Failure ────────────────────────────────────────
const logOAuthFailure = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Log OAuth Failure',
    position: [1664, 384],
    parameters: {
      jsCode:
        "const jobId = $('Validate Request Body').first().json.jobId;\n" +
        "const templateId = $('Validate Request Body').first().json.templateId;\n" +
        "const log = { level: 'ERROR', jobId, templateId, error: 'OAuth token request failed. Callback permanently failed.', timestamp: new Date().toISOString() };\n" +
        "console.log(JSON.stringify(log));\n" +
        "return log;"
    }
  },
  output: [{ level: 'ERROR' }]
});

// ── Compose Workflow ──────────────────────────────────────────────────
export default workflow('9ulAPRCgIgTVnIvz', 'Template Scan — Claude Vision (async)')
  .add(webhookTrigger)
  .to(checkApiKey)
  .to(authOk
    .onTrue(validateBody
      .to(bodyOk
        .onTrue(sendAck
          .to(buildClaudeReq
            .to(stripCarry
              .to(callClaude
                .to(parseValidateSchema
                  .to(schemaValid
                    .onTrue(buildSuccessPayload.to(mergePayloads))
                    .onFalse(buildErrorPayload.to(mergePayloads))
                  )
                )
              )
            )
          )
        )
        .onFalse(respond400)
      )
    )
    .onFalse(respond401)
  )
  .add(mergePayloads)
  .to(getSfToken)
  .to(oauthOk
    .onTrue(postCallback.to(logCompletion))
    .onFalse(logOAuthFailure)
  );
