// 隔离验证 fork 响应只返回配置元数据，不再次序列化聊天历史。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const swift = fs.readFileSync('codexBar/Services/CodexDesktopThreadSettingsService.swift', 'utf8');
const start = swift.indexOf('        (() => new Promise((resolve) => {');
let script = swift.slice(start, swift.indexOf('        """#', start));
script = script.replace('\\#(encoded)', Buffer.from(JSON.stringify({method:'thread/fork',params:{threadId:'source'}})).toString('base64'))
  .replace('\\#(method == "thread/fork" ? 60000 : 10000)', '60000');
let listener;
const thread = {id:'branch'};
Object.defineProperty(thread, 'turns', {enumerable:true,get(){throw Error('不能序列化完整历史');}});
const window = {
  addEventListener: (_, fn) => { listener = fn; },
  removeEventListener: () => { listener = null; },
  electronBridge:{sendMessageFromView: async envelope => {
    listener({data:{type:'mcp-response',message:{id:envelope.request.id,result:{thread,model:'fixture',reasoningEffort:'high'}}}});
  }}
};
(async()=>{
 const value = JSON.parse(await vm.runInNewContext(script,{window,atob:s=>Buffer.from(s,'base64').toString(),setTimeout,clearTimeout}));
 assert.deepEqual(value,{ok:true,result:{thread:{id:'branch'},model:'fixture',reasoningEffort:'high'}});
 assert.equal(listener,null);
 console.log('分支响应：元数据投影与监听清理检查通过');
})().catch(e=>{console.error(e);process.exitCode=1;});
