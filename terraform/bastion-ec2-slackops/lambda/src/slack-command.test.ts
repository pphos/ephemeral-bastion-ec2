import { createHmac } from 'node:crypto';
import type { LambdaFunctionURLEvent } from 'aws-lambda';
import { describe, expect, it } from 'vite-plus/test';
import { ACTION, REPLY_TEXT, decide, reply, toExecutionName } from './slack-command';

const SECRET = 'test-signing-secret';
const CHANNEL = 'C0DEDICATED';
const NOW = new Date('2027-01-15T00:00:00Z');
const NOW_SECONDS = NOW.getTime() / 1000;

function body(params: Record<string, string> = {}): string {
  return new URLSearchParams({
    command: '/bastion',
    text: 'start',
    channel_id: CHANNEL,
    user_id: 'U0USER',
    ...params,
  }).toString();
}

function sign(rawBody: string, timestamp: number, secret = SECRET): string {
  return `v0=${createHmac('sha256', secret).update(`v0:${timestamp}:${rawBody}`).digest('hex')}`;
}

function event(
  rawBody: string,
  options: { timestamp?: number; signature?: string; base64?: boolean } = {},
): LambdaFunctionURLEvent {
  const timestamp = options.timestamp ?? NOW_SECONDS;
  return {
    headers: {
      'x-slack-signature': options.signature ?? sign(rawBody, timestamp),
      'x-slack-request-timestamp': String(timestamp),
    },
    body: options.base64 ? Buffer.from(rawBody).toString('base64') : rawBody,
    isBase64Encoded: options.base64 ?? false,
  } as unknown as LambdaFunctionURLEvent;
}

describe('decide', () => {
  it.each([
    ['start', ACTION.start],
    ['stop', ACTION.stop],
    [' STOP ', ACTION.stop],
  ])('専用チャンネルの「%s」は、踏み台の操作にする', (text, action) => {
    expect(decide(event(body({ text })), SECRET, CHANNEL, NOW)).toEqual({
      kind: 'run',
      action,
      userId: 'U0USER',
    });
  });

  it('Base64 で届いた本文も、元に戻してから署名を確かめる', () => {
    expect(decide(event(body(), { base64: true }), SECRET, CHANNEL, NOW).kind).toBe('run');
  });

  it.each(['', 'restart', 'start now'])('引数が「%s」なら使い方を返す', (text) => {
    expect(decide(event(body({ text })), SECRET, CHANNEL, NOW)).toEqual({ kind: 'usage' });
  });

  it('専用チャンネル以外のコマンドは無視する', () => {
    expect(decide(event(body({ channel_id: 'C0OTHER' })), SECRET, CHANNEL, NOW)).toEqual({
      kind: 'ignore',
      channelId: 'C0OTHER',
    });
  });

  it('5 分以内のずれは受け付ける', () => {
    const decision = decide(event(body(), { timestamp: NOW_SECONDS - 300 }), SECRET, CHANNEL, NOW);

    expect(decision.kind).toBe('run');
  });

  it.each([
    ['署名のヘッダーがない', { ...event(body()), headers: {} }, 'missing-signature'],
    [
      'タイムスタンプが 5 分を超えてずれている',
      event(body(), { timestamp: NOW_SECONDS - 301 }),
      'stale-timestamp',
    ],
    [
      '別の Signing Secret で署名した',
      event(body(), { signature: sign(body(), NOW_SECONDS, 'another-secret') }),
      'signature-mismatch',
    ],
    ['署名の長さが違う', event(body(), { signature: 'v0=short' }), 'signature-mismatch'],
    [
      '署名のあとで本文が書き換えられた',
      { ...event(body()), body: body({ text: 'stop' }) },
      'signature-mismatch',
    ],
  ])('%sときは 401 で拒否する', (_, request, reason) => {
    expect(decide(request as LambdaFunctionURLEvent, SECRET, CHANNEL, NOW)).toEqual({
      kind: 'reject',
      statusCode: 401,
      reason,
    });
  });

  it('署名は合うが必要な項目が空なら 400 で拒否する', () => {
    expect(decide(event(body({ user_id: '' })), SECRET, CHANNEL, NOW)).toEqual({
      kind: 'reject',
      statusCode: 400,
      reason: 'invalid-slash-command',
    });
  });
});

describe('toExecutionName', () => {
  it('操作、打った人、時刻から、実行名を作る', () => {
    expect(toExecutionName(ACTION.start, 'U0USER', NOW)).toBe(`start-U0USER-${NOW.getTime()}`);
  });
});

describe('reply', () => {
  it('打った人にだけ見える応答を返す', () => {
    const result = reply(REPLY_TEXT.busy);

    expect(result.statusCode).toBe(200);
    expect(JSON.parse(result.body ?? '')).toEqual({
      response_type: 'ephemeral',
      text: REPLY_TEXT.busy,
    });
  });
});
