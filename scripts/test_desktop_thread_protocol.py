"""用官方 app-server 和本地模拟提供商验证下一轮参数；不读取用户配置或凭据。
运行：python3 scripts/test_desktop_thread_protocol.py /path/to/codex
"""
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading

requests = []
class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass
    def do_POST(self):
        requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for event in [
            {'type': 'response.created', 'response': {'id': 'resp_test', 'status': 'in_progress'}},
            {'type': 'response.completed', 'response': {'id': 'resp_test', 'status': 'completed',
                'output': [], 'usage': {'input_tokens': 10, 'output_tokens': 1, 'total_tokens': 11}}},
        ]:
            self.wfile.write(('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n').encode())
            self.wfile.flush()

with tempfile.TemporaryDirectory(prefix='codex-box-protocol-') as home:
    server = http.server.HTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    catalog_config = ''
    catalog = None
    if len(sys.argv) > 2:
        catalog = json.loads(Path(sys.argv[2]).read_text())
        Path(home, 'catalog.json').write_text(json.dumps({'models':catalog['models']}))
        catalog_config = f'model_catalog_json = \"{home}/catalog.json\"\n'
    Path(home, 'config.toml').write_text(
        catalog_config + 'model_provider = "fixture"\n[model_providers.fixture]\nname = "Fixture"\n'
        f'base_url = "http://127.0.0.1:{server.server_port}/v1"\nwire_api = "responses"\n')
    env = {**os.environ, 'CODEX_HOME': home, 'NO_PROXY': '127.0.0.1,localhost', 'no_proxy': '127.0.0.1,localhost'}
    for key in ('OPENAI_API_KEY', 'CODEX_API_KEY', 'OPENAI_BASE_URL'):
        env.pop(key, None)
    with open(Path(home, 'stderr.log'), 'w') as log:
        process = subprocess.Popen([sys.argv[1], 'app-server'], cwd=home, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        incoming = queue.Queue()
        def reader():
            for line in process.stdout:
                incoming.put(json.loads(line))
        threading.Thread(target=reader, daemon=True).start()
        sequence = 0
        notes = []
        def receive():
            return incoming.get(timeout=30)
        def call(method, params):
            global sequence
            sequence += 1
            process.stdin.write(json.dumps({'id': sequence, 'method': method, 'params': params}) + '\n')
            process.stdin.flush()
            while True:
                message = receive()
                if message.get('id') == sequence:
                    assert 'error' not in message, message.get('error')
                    return message['result']
                notes.append(message)
        def turn(thread_id):
            notes.clear()
            call('turn/start', {'threadId': thread_id, 'input': [{'type': 'text', 'text': 'Reply OK'}]})
            while not any(n.get('method') == 'turn/completed' for n in notes):
                notes.append(receive())
            completed = next(n for n in notes if n.get('method') == 'turn/completed')
            assert completed['params']['turn']['status'] == 'completed', completed
            return next(n['params']['tokenUsage']['modelContextWindow'] for n in notes
                if n.get('method') == 'thread/tokenUsage/updated')
        try:
            call('initialize', {'clientInfo': {'name': 'codex-box-test', 'version': '1'},
                'capabilities': {'experimentalApi': True}})
            first = call('thread/start', {'model': 'gpt-5.6-sol', 'cwd': home,
                'approvalPolicy': 'never', 'config': {'model_context_window': 272000}})['thread']['id']
            original_window = turn(first)
            second = call('thread/start', {'model': 'gpt-5.6-astra', 'cwd': home,
                'approvalPolicy': 'never'})['thread']['id']
            call('thread/settings/update', {'threadId': second, 'effort': 'high'})
            for tid, expected in [(first, 'gpt-5.6-sol'), (second, 'gpt-5.6-astra'), (first, 'gpt-5.6-sol')]:
                assert call('thread/read', {'threadId': tid, 'includeTurns': False})['thread']['model'] == expected
            call('thread/settings/update', {'threadId': first, 'model': 'gpt-5.6-astra', 'effort': 'high', 'serviceTier': 'fast'})
            actual = call('thread/read', {'threadId': first, 'includeTurns': False})['thread']
            assert (actual['model'], actual['reasoningEffort']) == ('gpt-5.6-astra', 'high')
            setting_notes = list(notes)
            turn(first)
            assert requests[-1]['model'] == 'gpt-5.6-astra'
            assert requests[-1]['reasoning']['effort'] == 'high'
            assert any(n.get('method') == 'thread/settings/updated' and n['params']['threadSettings'].get('serviceTier') == 'priority' for n in setting_notes + notes), 'Fast 桌面同步通知缺失'
            call('thread/resume', {'threadId': first, 'excludeTurns': True,
                'config': {'model_context_window': 123456}})
            assert turn(first) == original_window, '上游上下文行为已变化，需重新评估在线窗口修改'
            source_history = call('thread/read', {'threadId':first,'includeTurns':True})['thread']['turns']
            fork_result = call('thread/fork', {'threadId':first,'excludeTurns':True,'config':{'model_context_window':123456}})
            assert not fork_result['thread'].get('turns'), '创建响应不应展开历史'
            fork = fork_result['thread']['id']
            assert fork != first
            inherited = call('thread/read', {'threadId':fork,'includeTurns':True})['thread']['turns']
            assert len(inherited) == len(source_history), '分支必须继承历史'
            fork_window = turn(fork)
            assert fork_window == 123456 * 95 // 100, fork_window
            assert turn(first) == original_window, '原对话窗口不应改变'
            print('通过：继承完整历史创建分支，无需重启；设置窗口 123456，实际窗口', fork_window)
            print('通过：模型与思考强度读回、Fast 同步通知、原对话窗口保持不变。')
            metadata = next((m for m in (catalog or {}).get('models',[]) if m.get('slug') == 'gpt-5.6-sol'), None)
            if metadata:
                for configured in [258000, 512000, 1000000, 1050000]:
                    branch = call('thread/fork', {'threadId':first,'model':'gpt-5.6-sol','excludeTurns':True,
                        'config':{'model_context_window':configured}})['thread']['id']
                    reported = turn(branch)
                    expected = min(configured, metadata['max_context_window']) * metadata['effective_context_window_percent'] // 100
                    assert reported == expected, (configured, reported, expected)
                    print(f'档位 {configured}：实际上报 {reported}，符合模型上限与有效比例')

        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            server.shutdown()
