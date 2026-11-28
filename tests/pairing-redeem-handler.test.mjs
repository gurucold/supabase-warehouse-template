import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handle } from '../functions/pairing-redeem/handler.ts';
import { deviceNameCases } from './device-name-cases.mjs';

// WH-411: what the pairing sign-in of a local-only facility sends to the database. No network: the RPC is this stand-in.
const environment = { INGRESS: 'local-only', SUPABASE_URL: 'http://rest.test', SUPABASE_SERVICE_ROLE_KEY: 'unit-test-service-key' };
const request = { code: 'ABCD2345', nonce: 'a'.repeat(64) };

async function redeem(extra, headers = {}) {
  const calls = [];
  const fetchStub = async (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    return Response.json({ ok: true, secret: 'b'.repeat(64), session: { access_token: 'a', refresh_token: 'r' } });
  };
  const response = await handle(new Request('http://edge.test/pairing-redeem', {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify({ ...request, ...extra }),
  }), name => environment[name], fetchStub);
  return { status: response.status, body: await response.json(), calls };
}

test('without a phone name the redeem RPC gets the code, the address and the user agent only', async () => {
  const { status, body, calls } = await redeem({}, { 'CF-Connecting-IP': '203.0.113.9', 'User-Agent': 'okhttp/4.9.2' });
  assert.equal(status, 200);
  assert.equal(body.success, true);
  assert.match(body.data.ciphertext, /^[0-9a-f]+$/);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'http://rest.test/rest/v1/rpc/redeem_pairing_code');
  assert.deepEqual(calls[0].body, { p_code: 'ABCD2345', p_ip: '203.0.113.9', p_user_agent: 'okhttp/4.9.2' });
});

test('WH-411, WH-424: the phone name of the body goes to the redeem RPC as p_device_name, cleaned and cut to 80 code points; otherwise the key is left out and the sign-in goes on', async () => {
  for (const [sent, expected] of deviceNameCases) {
    const { status, calls } = await redeem({ device_name: sent });
    assert.equal(status, 200, JSON.stringify(sent));
    assert.equal(Object.hasOwn(calls[0].body, 'p_device_name'), expected !== undefined, JSON.stringify(sent));
    assert.equal(calls[0].body.p_device_name, expected, JSON.stringify(sent));
    assert.equal(calls[0].body.p_user_agent, null);
  }
});
