import { workflow, node, trigger, ifElse } from '@n8n/workflow-sdk';

// ─────────────────────────────────────────────────────────────────────
// AI Prompt Edit — Claude Sync
// TypeScript (Workflow SDK) representation of ai-prompt-edit-workflow.json.
//
// Flow:
//   Webhook /schema-edit
//     → Check API Key → Auth OK?
//        ├─ false → Respond 401
//        └─ true  → Validate Request Body → Body OK?
//                     ├─ false → Respond 400
//                     └─ true  → Build Claude Edit Request → Call Claude (Edit)
//                                  → Parse & Validate Edit → Edit Valid?
//                                       ├─ true  → Respond 200 (Success)
//                                       └─ false → Retry? (attempt < 2)
//                                                    ├─ true  → Prepare Retry ──┐
//                                                    └─ false → Respond 422     │
//                                                                               │
//                          ┌────────────────────────────────────────────────────┘
//                          └─ loops back into "Build Claude Edit Request"
// ─────────────────────────────────────────────────────────────────────

// ── Trigger: Webhook — /schema-edit ───────────────────────────────────
const webhookTrigger = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2,
  config: {
    name: 'Webhook — /schema-edit',
    position: [250, 300],
    parameters: {
      httpMethod: 'POST',
      path: 'schema-edit',
      responseMode: 'responseNode',
      options: { rawBody: true, responseData: 'allEntries' }
    }
  },
  output: [{ headers: { authorization: 'Basic ...' }, body: {} }]
});

// ── Node: Check API Key ───────────────────────────────────────────────
const checkApiKey = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Check API Key',
    position: [450, 300],
    parameters: {
      jsCode:
        "// Validate Basic Auth. Same shared credentials as Template Scan workflow.\n" +
        "// Salesforce Named Credential sends Authorization: Basic <base64>.\n" +
        "const authHeader = $input.first().json.headers['authorization'] || '';\n" +
        "const expectedUser = $env.N8N_AUTH_USER || 'n3n';\n" +
        "const expectedPass = $env.N8N_AUTH_PASS || 'Kampret#1.';\n" +
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

// ── Node: Auth OK? ────────────────────────────────────────────────────
const authOk = ifElse({
  version: 2,
  config: {
    name: 'Auth OK?',
    position: [650, 300],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ id: 'cond-eauth-1', leftValue: '={{ $json.valid }}', rightValue: true, operator: { type: 'boolean', operation: 'equals' } }],
        combinator: 'and'
      },
      options: {}
    }
  }
});

// ── Node: Respond 401 ─────────────────────────────────────────────────
const respond401 = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1,
  config: {
    name: 'Respond 401',
    position: [850, 400],
    parameters: {
      respondWith: 'json',
      responseBody: '={"status":"error","error":"Unauthorized"}',
      options: { responseStatusCode: 401 }
    }
  },
  output: [{}]
});

// ── Node: Validate Request Body ───────────────────────────────────────
const validateBody = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Validate Request Body',
    position: [450, 600],
    parameters: {
      jsCode:
        "// Validate Edit Request Body: templateId (non-empty, max 255),\n" +
        "// currentSchema (object), prompt (non-empty, max 2000).\n" +
        "// NOTE: read the body from the Webhook node by name -- the upstream\n" +
        "// 'Check API Key' Code node returns only { valid: true }, so $input no\n" +
        "// longer carries .body. Referencing the webhook directly restores it.\n" +
        "const body = $('Webhook — /schema-edit').first().json.body;\n" +
        "if (!body || typeof body !== 'object') return { valid: false, error: 'Request body must be a JSON object.' };\n" +
        "if (!body.templateId || typeof body.templateId !== 'string' || body.templateId.trim() === '') return { valid: false, error: 'Missing or empty templateId.' };\n" +
        "if (body.templateId.length > 255) return { valid: false, error: 'templateId exceeds 255 characters.' };\n" +
        "if (!body.currentSchema || typeof body.currentSchema !== 'object' || Array.isArray(body.currentSchema)) return { valid: false, error: 'currentSchema must be a JSON object.' };\n" +
        "if (!body.prompt || typeof body.prompt !== 'string' || body.prompt.trim() === '') return { valid: false, error: 'Missing or empty prompt.' };\n" +
        "if (body.prompt.length > 2000) return { valid: false, error: 'prompt exceeds 2000 characters.' };\n" +
        "return {\n" +
        "  valid: true,\n" +
        "  templateId: body.templateId,\n" +
        "  currentSchema: body.currentSchema,\n" +
        "  prompt: body.prompt.trim(),\n" +
        "  _currentSchemaJson: JSON.stringify(body.currentSchema)\n" +
        "};"
    }
  },
  output: [{ valid: true, templateId: 'a0B...', currentSchema: {}, prompt: '...', _currentSchemaJson: '{}' }]
});

// ── Node: Body OK? ────────────────────────────────────────────────────
const bodyOk = ifElse({
  version: 2,
  config: {
    name: 'Body OK?',
    position: [650, 600],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ id: 'cond-ebody-1', leftValue: '={{ $json.valid }}', rightValue: true, operator: { type: 'boolean', operation: 'equals' } }],
        combinator: 'and'
      },
      options: {}
    }
  }
});

// ── Node: Respond 400 ─────────────────────────────────────────────────
const respond400 = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1,
  config: {
    name: 'Respond 400',
    position: [850, 700],
    parameters: {
      respondWith: 'json',
      responseBody: '={"status":"error","error":"{{ $json.error }}"}',
      options: { responseStatusCode: 400 }
    }
  },
  output: [{}]
});

// ── Node: Build Claude Edit Request ───────────────────────────────────
// System prompt carries the full schema contract (id immutability, colSpan ≤ 12,
// output format { schema, changes }). If _retryHint is set, appends error feedback.
const buildClaudeReq = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Claude Edit Request',
    position: [1050, 300],
    parameters: {
      jsCode:
        "const prev = $input.first().json;\n" +
        "const retryHint = prev._retryHint || '';\n" +
        "const SYSTEM_PROMPT = [\n" +
        "  'You are a form schema editor. You receive a current form schema JSON and a natural-language edit prompt.',\n" +
        "  'Apply the requested modification and return a single valid JSON object with exactly two keys:',\n" +
        "  '{ \"schema\": <the modified form schema object>, \"changes\": [\"<human-readable description of each change made>\"] }',\n" +
        "  '',\n" +
        "  'SCHEMA CONTRACT:',\n" +
        "  '- schemaVersion: 1',\n" +
        "  '- sections -> rows -> fields',\n" +
        "  '- Field types: text, textarea, number, date, time, checkbox, picklist, table, signature',\n" +
        "  '- colSpan: 1-12 per field; sum per row <= 12',\n" +
        "  '- type \"html\" is FORBIDDEN',\n" +
        "  '- signature fields require signerRole: \"engineer\" | \"supervisor\"',\n" +
        "  '- picklist fields require non-empty \"options\" array of strings',\n" +
        "  '- table fields require non-empty \"columns\" array with { id, label, type }',\n" +
        "  '- All field \"id\" values must be unique across the entire schema',\n" +
        "  '',\n" +
        "  'CRITICAL RULES:',\n" +
        "  '1. Field \"id\" values are IMMUTABLE -- never rename or delete an existing id. You MAY add new ids for new fields.',\n" +
        "  '2. The output schema must pass all structural validation rules above.',\n" +
        "  '3. Output ONLY the JSON object -- no preamble, no markdown fences, no explanation.',\n" +
        "  retryHint ? ('\\nPREVIOUS ATTEMPT FAILED: ' + retryHint + '\\nFix the error and try again.') : ''\n" +
        "].join('\\n');\n" +
        "return {\n" +
        "  model: 'claude-sonnet-4-5',\n" +
        "  max_tokens: 4096,\n" +
        "  temperature: 0.1,\n" +
        "  system: SYSTEM_PROMPT,\n" +
        "  messages: [{ role: 'user', content: 'CURRENT SCHEMA:\\n' + JSON.stringify(prev.currentSchema, null, 2) + '\\n\\nEDIT PROMPT:\\n' + prev.prompt }],\n" +
        "  _templateId: prev.templateId,\n" +
        "  _currentSchemaJson: prev._currentSchemaJson,\n" +
        "  _attempt: prev._attempt || 1\n" +
        "};"
    }
  },
  output: [{ model: 'claude-sonnet-4-5', max_tokens: 4096, temperature: 0.1, _templateId: 'a0B...', _currentSchemaJson: '{}', _attempt: 1 }]
});

// ── Node: Call Claude (Edit) ──────────────────────────────────────────
const callClaude = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4,
  config: {
    name: 'Call Claude (Edit)',
    position: [1250, 300],
    // continueErrorOutput exposes a second (error) output so a Claude failure
    // (auth, rate limit, timeout, network) routes to Respond 502 instead of
    // aborting the run and returning an empty webhook body.
    onError: 'continueErrorOutput',
    parameters: {
      method: 'POST',
      url: 'https://api.anthropic.com/v1/messages',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpHeaderAuth',
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'anthropic-version', value: '2023-06-01' },
          { name: 'content-type', value: 'application/json' }
        ]
      },
      sendBody: true,
      specifyBody: 'json',
      // Send ONLY the fields the Anthropic Messages API accepts. The carry-forward
      // (_-prefixed) fields stay on this node's output for downstream nodes, but
      // must NOT be sent to Anthropic (it 400s on any unknown top-level field).
      jsonBody: '={{ JSON.stringify({ model: $json.model, max_tokens: $json.max_tokens, temperature: $json.temperature, system: $json.system, messages: $json.messages }) }}',
      options: { timeout: 60000, response: { response: { responseFormat: 'json' } } }
    }
  },
  output: [{ content: [{ type: 'text', text: '{"schema":{},"changes":[]}' }] }]
});

// ── Node: Respond 502 (Claude failure) ────────────────────────────────
// Reached only via the error output of "Call Claude (Edit)". Guarantees a
// parseable JSON body so Salesforce never sees an empty 2xx response.
const respond502 = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1,
  config: {
    name: 'Respond 502 (Claude failure)',
    position: [1450, 520],
    parameters: {
      respondWith: 'json',
      responseBody: '={"status":"error","error":{{ JSON.stringify("Claude call failed: " + (($json.error && $json.error.message) ? $json.error.message : "see n8n execution log")) }}}',
      options: { responseStatusCode: 502 }
    }
  },
  output: [{}]
});

// ── Node: Parse & Validate Edit ───────────────────────────────────────
// Same structural rules as scan, PLUS id preservation vs the prior schema.
const parseValidate = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Parse & Validate Edit',
    position: [1450, 300],
    parameters: {
      jsCode:
        "const claudeRes = $input.first().json;\n" +
        "const carry = $('Build Claude Edit Request').first().json;\n" +
        "const currentSchema = JSON.parse(carry._currentSchemaJson);\n" +
        "const attempt = carry._attempt;\n" +
        "function fail(msg, attempt, rawOutput) {\n" +
        "  return {\n" +
        "    valid: false,\n" +
        "    error: msg,\n" +
        "    _templateId: carry._templateId,\n" +
        "    _currentSchemaJson: carry._currentSchemaJson,\n" +
        "    _prompt: $('Validate Request Body').first().json.prompt,\n" +
        "    _attempt: attempt,\n" +
        "    _retryHint: 'Validation error on attempt ' + attempt + ': ' + msg,\n" +
        "    _rawOutput: rawOutput\n" +
        "  };\n" +
        "}\n" +
        "function collectFieldIds(schema) {\n" +
        "  const ids = [];\n" +
        "  if (!schema.sections || !Array.isArray(schema.sections)) return ids;\n" +
        "  for (const s of schema.sections) {\n" +
        "    if (!s.rows || !Array.isArray(s.rows)) continue;\n" +
        "    for (const r of s.rows) {\n" +
        "      if (!r.fields || !Array.isArray(r.fields)) continue;\n" +
        "      for (const f of r.fields) { if (f.id && typeof f.id === 'string') ids.push(f.id); }\n" +
        "    }\n" +
        "  }\n" +
        "  return ids;\n" +
        "}\n" +
        "const text = (claudeRes.content || []).filter(c => c.type === 'text').map(c => c.text).join('\\n');\n" +
        "if (!text || text.trim() === '') return fail('Claude returned empty response.', attempt, null);\n" +
        "let cleaned = text.trim();\n" +
        "if (cleaned.startsWith('```')) cleaned = cleaned.replace(/^```(?:json)?\\s*\\n?/, '').replace(/\\n?```\\s*$/, '');\n" +
        "let result;\n" +
        "try { result = JSON.parse(cleaned); } catch (e) { return fail('Claude output is not parseable JSON: ' + e.message, attempt, null); }\n" +
        "if (!result.schema || typeof result.schema !== 'object') return fail('Response missing \"schema\" object.', attempt, cleaned.substring(0, 500));\n" +
        "if (!result.changes || !Array.isArray(result.changes)) return fail('Response missing \"changes\" array.', attempt, cleaned.substring(0, 500));\n" +
        "const schema = result.schema;\n" +
        "const changes = result.changes;\n" +
        "const ALLOWED_TYPES = new Set(['text','textarea','number','date','time','checkbox','picklist','table','signature']);\n" +
        "const ALLOWED_SIGNER = new Set(['engineer','supervisor']);\n" +
        "const errors = []; const newFieldIds = new Set();\n" +
        "if (!schema.sections || !Array.isArray(schema.sections)) { errors.push('Schema missing \"sections\" array.'); }\n" +
        "else {\n" +
        "  for (const section of schema.sections) {\n" +
        "    if (!section.rows || !Array.isArray(section.rows)) continue;\n" +
        "    for (const row of section.rows) {\n" +
        "      if (!row.fields || !Array.isArray(row.fields)) continue;\n" +
        "      let colSum = 0;\n" +
        "      for (const field of row.fields) {\n" +
        "        if (!field.id || typeof field.id !== 'string') { errors.push('Field missing string id.'); continue; }\n" +
        "        if (newFieldIds.has(field.id)) errors.push('Duplicate field id: ' + field.id);\n" +
        "        newFieldIds.add(field.id);\n" +
        "        const type = field.type;\n" +
        "        if (!type || !ALLOWED_TYPES.has(type)) errors.push('Field \"' + field.id + '\" disallowed type \"' + type + '\".');\n" +
        "        const colSpan = field.colSpan || 0;\n" +
        "        if (colSpan < 1 || colSpan > 12) errors.push('Field \"' + field.id + '\" colSpan ' + colSpan + ' out of range.');\n" +
        "        colSum += colSpan;\n" +
        "        if (type === 'picklist' && (!field.options || !Array.isArray(field.options) || field.options.length === 0)) errors.push('Picklist \"' + field.id + '\" requires non-empty options.');\n" +
        "        if (type === 'signature' && (!field.signerRole || !ALLOWED_SIGNER.has(field.signerRole))) errors.push('Signature \"' + field.id + '\" requires signerRole: engineer|supervisor.');\n" +
        "        if (type === 'table' && (!field.columns || !Array.isArray(field.columns) || field.columns.length === 0)) errors.push('Table \"' + field.id + '\" requires non-empty columns.');\n" +
        "      }\n" +
        "      if (colSum > 12) errors.push('Row colSpan sum exceeds 12.');\n" +
        "    }\n" +
        "  }\n" +
        "}\n" +
        "const oldIds = collectFieldIds(currentSchema);\n" +
        "const missing = oldIds.filter(id => !newFieldIds.has(id));\n" +
        "if (missing.length > 0) errors.push('ID PRESERVATION VIOLATION: removed/renamed field ids: ' + missing.join(', '));\n" +
        "if (errors.length > 0) return fail(errors.join(' | '), attempt, cleaned.substring(0, 500));\n" +
        "return { valid: true, schema, changes, _templateId: carry._templateId, _attempt: attempt };"
    }
  },
  output: [{ valid: true, schema: { sections: [] }, changes: [], _templateId: 'a0B...', _attempt: 1 }]
});

// ── Node: Edit Valid? ─────────────────────────────────────────────────
const editValid = ifElse({
  version: 2,
  config: {
    name: 'Edit Valid?',
    position: [1650, 300],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ id: 'cond-evalid-1', leftValue: '={{ $json.valid }}', rightValue: true, operator: { type: 'boolean', operation: 'equals' } }],
        combinator: 'and'
      },
      options: {}
    }
  }
});

// ── Node: Respond 200 (Success) ───────────────────────────────────────
const respondSuccess = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1,
  config: {
    name: 'Respond 200 (Success)',
    position: [1850, 150],
    parameters: {
      respondWith: 'json',
      responseBody: '={"status":"success","schema":{{ JSON.stringify($json.schema) }},"changes":{{ JSON.stringify($json.changes) }}}',
      options: { responseStatusCode: 200 }
    }
  },
  output: [{}]
});

// ── Node: Retry? (attempt < 2) ────────────────────────────────────────
const retryIf = ifElse({
  version: 2,
  config: {
    name: 'Retry? (attempt < 2)',
    position: [1850, 450],
    parameters: {
      conditions: {
        options: { caseSensitive: true },
        conditions: [{ id: 'cond-eretry-1', leftValue: '={{ $json._attempt }}', rightValue: 1, operator: { type: 'number', operation: 'equals' } }],
        combinator: 'and'
      },
      options: {}
    }
  }
});

// ── Node: Prepare Retry ───────────────────────────────────────────────
// Increments attempt counter and injects the error hint so Build Claude Edit
// Request includes it in the system prompt on the second attempt.
const prepareRetry = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Retry',
    position: [2050, 450],
    parameters: {
      jsCode:
        "const fail = $input.first().json;\n" +
        "return {\n" +
        "  valid: true,\n" +
        "  templateId: fail._templateId,\n" +
        "  currentSchema: JSON.parse(fail._currentSchemaJson),\n" +
        "  prompt: $('Validate Request Body').first().json.prompt,\n" +
        "  _currentSchemaJson: fail._currentSchemaJson,\n" +
        "  _retryHint: fail._retryHint,\n" +
        "  _attempt: (fail._attempt || 1) + 1\n" +
        "};"
    }
  },
  output: [{ valid: true, templateId: 'a0B...', currentSchema: {}, prompt: '...', _attempt: 2 }]
});

// ── Node: Respond 422 (Failed) ────────────────────────────────────────
const respond422 = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1,
  config: {
    name: 'Respond 422 (Failed)',
    position: [2050, 600],
    parameters: {
      respondWith: 'json',
      responseBody: '={"status":"error","error":"AI edit failed after 2 attempts: {{ $json.error }}"}',
      options: { responseStatusCode: 422 }
    }
  },
  output: [{}]
});

// ── Compose Workflow ──────────────────────────────────────────────────
// Note: prepareRetry loops back into buildClaudeReq (the retry edge), mirroring
// the "Prepare Retry → Build Claude Edit Request" connection in the JSON.
export default workflow('1.0.0-edit', 'AI Prompt Edit — Claude Sync')
  .add(webhookTrigger)
  .to(checkApiKey)
  .to(authOk
    .onTrue(validateBody
      .to(bodyOk
        .onTrue(buildClaudeReq
          .to(callClaude
            .onError(respond502)
            .to(parseValidate
              .to(editValid
                .onTrue(respondSuccess)
                .onFalse(retryIf
                  .onTrue(prepareRetry.to(buildClaudeReq))
                  .onFalse(respond422)
                )
              )
            )
          )
        )
        .onFalse(respond400)
      )
    )
    .onFalse(respond401)
  );
