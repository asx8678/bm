// Stand-in for `pi --mode rpc` in tests. Speaks the same JSONL protocol with scripted replies:
//   "tool ..."  -> runs a fake `read` tool, then answers
//   "fail"      -> the assistant message ends with an error
//   "dialog"    -> asks a confirm dialog and answers with how it was resolved
//   "crash"     -> exits with status 3
//   "report"    -> reports telemetry through a bm: notify record
//   "bm-dialog" -> asks the BEAM through a bm: input dialog and answers with the reply it got
//   "bm-bad"    -> sends a bm: input dialog with a malformed request
//   "nocost"    -> answers, but the assistant message carries no usage/cost
//   "break-reset" -> answers; the next new_session command fails
//   "plan"      -> streams three add_task calls OpenAI-style (all toolcall_end events at the end)
//   "spawn-child" -> leaves processes behind like pi's bash tool: a detached shell that records its
//                  group id in BM_PGID_FILE (as bm_guard's prefix does) and starts a background
//                  job, plus a plain child in pi's own group; then answers
//   "work:<json>" -> runs scripted steps like a worker, then answers "worked" (see runWork)
//   "plan:<json>" -> a scripted planner: a list of waves; the prompt runs the first wave and each
//                  follow_up the next one (see runPlanWave); without waves left, follow_ups are
//                  answered "followed: ..."
//   anything    -> answers "echo: <message>"
import {spawn} from "node:child_process"
import {randomUUID} from "node:crypto"
import {writeFileSync, mkdirSync} from "node:fs"
import {dirname} from "node:path"

let buffer = ""
let waitingDialog = null
let waitingBm = null
let failNextReset = false
// Dialogs sent by runWork, waiting for the BEAM's extension_ui_response: id -> resolve.
const pendingDialogs = new Map()
let abortWork = null
let workAborted = false
// Remaining scripted planner waves (plan:<json>).
let planWaves = null

const send = record => process.stdout.write(JSON.stringify(record) + "\n")
const usage = {input: 10, output: 2, cacheRead: 5, cacheWrite: 0, totalTokens: 17}

const finalUsage = {...usage, cost: {input: 0.001, output: 0.002, cacheRead: 0, cacheWrite: 0, total: 0.003}}

function answer(text, stopReason = "stop", errorMessage, withCost = true) {
  send({type: "message_start", message: {role: "assistant", content: [], stopReason: "pending"}})
  if (text) send({type: "message_update", usage, assistantMessageEvent: {type: "text_delta", contentIndex: 0, delta: text}})
  send({type: "message_end", message: {role: "assistant", stopReason, errorMessage, ...(withCost ? {usage: finalUsage} : {})}})
  send({type: "agent_end", messages: [], willRetry: false})
  send({type: "agent_settled"})
}

function streamPlan() {
  const update = event => send({type: "message_update", usage, assistantMessageEvent: event})
  const calls = ["a", "b", "c"].map((id, index) => ({index, id, args: JSON.stringify({id, title: `Task ${id}`})}))
  send({type: "message_start", message: {role: "assistant", content: [], stopReason: "pending"}})
  for (const call of calls) {
    update({type: "toolcall_start", contentIndex: call.index, id: `call-${call.id}`, toolName: "add_task"})
    const middle = Math.floor(call.args.length / 2)
    update({type: "toolcall_delta", contentIndex: call.index, delta: call.args.slice(0, middle)})
    update({type: "toolcall_delta", contentIndex: call.index, delta: call.args.slice(middle)})
  }
  for (const call of calls) {
    update({type: "toolcall_end", contentIndex: call.index,
            toolCall: {type: "toolCall", id: `call-${call.id}`, name: "add_task", arguments: JSON.parse(call.args)}})
  }
  send({type: "message_end", message: {role: "assistant", stopReason: "toolUse"}})
  send({type: "agent_end", messages: [], willRetry: false})
  send({type: "agent_settled"})
}

// Asks the BEAM through a bm: input dialog, like bm_common's bmRequest; resolves to its reply.
function bmRequest(op, payload, requestId = randomUUID()) {
  const id = `work-${randomUUID()}`
  const request = {v: 1, op, request_id: requestId, payload}
  send({type: "extension_ui_request", id, method: "input", title: `bm:${op}`, placeholder: JSON.stringify(request)})
  return new Promise(resolve => pendingDialogs.set(id, value => resolve(value === undefined ? {ok: false} : JSON.parse(value))))
}

// Like pi's bash tool with bm_guard's prefix: a detached shell per command (own session) that
// records its group id in BM_PGID_FILE. Resolves when the shell exits.
function runShell(command) {
  const script = `printf '%s\\n' "$$" >> "$BM_PGID_FILE"\n${command}`
  return new Promise(resolve => spawn("sh", ["-c", script], {detached: true, stdio: "ignore"}).on("exit", resolve))
}

// Steps: {"authorize": {tool, input}} stops the work when denied; {"bash": cmd} authorizes, then
// runs cmd (stops when denied); {"write": [path, text]} writes directly, as a tool would;
// {"spawn": cmd} starts cmd in the background like a bash tool call; {"submit": {status, summary},
// "request_id"?: id}; {"hang": true} waits until aborted; {"message": text, "cost"?: false} sends
// an assistant message (with a cost unless cost is false) without finishing; {"busy": ms} keeps
// streaming text for ms.
async function runWork(steps) {
  workAborted = false
  for (const step of steps) {
    if (step.authorize) {
      const reply = await bmRequest("authorize", step.authorize)
      if (!reply.allow) return answer(`denied: ${reply.reason ?? reply.error}`)
    } else if (step.bash) {
      const reply = await bmRequest("authorize", {tool: "bash", input: {command: step.bash}})
      if (!reply.allow) return answer(`denied: ${reply.reason ?? reply.error}`)
      send({type: "tool_execution_start", toolCallId: "bash-1", toolName: "bash", args: {command: step.bash}})
      await runShell(step.bash)
      send({type: "tool_execution_end", toolCallId: "bash-1", toolName: "bash", result: {content: []}, isError: false})
    } else if (step.write) {
      const [path, text] = step.write
      mkdirSync(dirname(path), {recursive: true})
      writeFileSync(path, text)
    } else if (step.spawn) {
      runShell(`${step.spawn} >/dev/null 2>&1 &`)
      await new Promise(resolve => setTimeout(resolve, 100))
    } else if (step.submit) {
      await bmRequest("submit_result", step.submit, step.request_id)
    } else if (step.message !== undefined) {
      send({type: "message_start", message: {role: "assistant", content: [], stopReason: "pending"}})
      send({type: "message_update", usage, assistantMessageEvent: {type: "text_delta", contentIndex: 0, delta: step.message}})
      send({type: "message_end", message: {role: "assistant", stopReason: "toolUse", ...(step.cost === false ? {} : {usage: finalUsage})}})
    } else if (step.busy) {
      const until = Date.now() + step.busy
      while (Date.now() < until && !workAborted) {
        send({type: "message_update", usage, assistantMessageEvent: {type: "text_delta", contentIndex: 0, delta: "."}})
        await new Promise(resolve => setTimeout(resolve, 20))
      }
      if (workAborted) return answer("aborted", "aborted")
    } else if (step.hang) {
      if (!workAborted) await new Promise(resolve => { abortWork = resolve })
      return answer("aborted", "aborted")
    }
  }
  answer("worked")
}

// A planner wave: {"tasks": [proposal, ...], "close": true (default) | false, "summary": text,
// "write": [path, text] (writes a file first, like a misbehaving planner), "bash": cmd (asks
// authorize, runs it if allowed), "stream_hang": true (streams a propose_task call without ever
// sending its dialog, then waits until aborted), "hang": true (waits until aborted at the end)}.
// Answers with one line per proposal: "key: accepted" or "key: rejected (reason)".
async function runPlanWave(wave) {
  workAborted = false
  const lines = []
  if (wave.write) {
    const [path, text] = wave.write
    mkdirSync(dirname(path), {recursive: true})
    writeFileSync(path, text)
  }
  if (wave.bash) {
    const reply = await bmRequest("authorize", {tool: "bash", input: {command: wave.bash}})
    if (reply.allow) await runShell(wave.bash)
    lines.push(`bash: ${reply.allow ? "ran" : `denied (${reply.reason})`}`)
  }
  if (wave.stream_hang) {
    const update = event => send({type: "message_update", usage, assistantMessageEvent: event})
    send({type: "message_start", message: {role: "assistant", content: [], stopReason: "pending"}})
    update({type: "toolcall_start", contentIndex: 0, id: "call-p", toolName: "propose_task"})
    update({type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(wave.tasks?.[0] ?? {key: "x"})})
    if (!workAborted) await new Promise(resolve => { abortWork = resolve })
    return answer("aborted", "aborted")
  }
  for (const task of wave.tasks ?? []) {
    const reply = await bmRequest("propose_task", task)
    lines.push(`${task.key}: ${reply.status ?? reply.error}${reply.reason ? ` (${reply.reason})` : ""}`)
  }
  if (wave.close !== false) await bmRequest("close_plan", {summary: wave.summary ?? "planned"})
  if (wave.hang) {
    if (!workAborted) await new Promise(resolve => { abortWork = resolve })
    return answer("aborted", "aborted")
  }
  answer(lines.join("; ") || "planned")
}

function handle(command) {
  if (command.type === "get_state") {
    send({id: command.id, type: "response", command: "get_state", success: true,
          data: {model: {id: "fake-model", name: "Fake Model"}, isStreaming: false,
                 // Echo the environment guard so tests can check it reached the process.
                 sessionName: process.env.PI_FABRIC_DEPTH ? `depth-${process.env.PI_FABRIC_DEPTH}` : undefined}})
  } else if (command.type === "new_session") {
    if (failNextReset) {
      failNextReset = false
      send({id: command.id, type: "response", command: "new_session", success: false, error: "reset refused"})
    } else {
      send({id: command.id, type: "response", command: "new_session", success: true, data: {cancelled: false}})
    }
  } else if (command.type === "follow_up") {
    send({id: command.id, type: "response", command: "follow_up", success: true})
    send({type: "agent_start"})
    if (planWaves && planWaves.length > 0) runPlanWave(planWaves.shift())
    else answer(`followed: ${command.message}`)
  } else if (command.type === "extension_ui_response" && waitingBm === command.id) {
    waitingBm = null
    answer(`bm reply: ${command.value ?? "cancelled"}`)
  } else if (command.type === "extension_ui_response" && pendingDialogs.has(command.id)) {
    const resolve = pendingDialogs.get(command.id)
    pendingDialogs.delete(command.id)
    resolve(command.cancelled ? undefined : command.value)
  } else if (command.type === "abort") {
    send({id: command.id, type: "response", command: "abort", success: true})
    if (abortWork) { abortWork(); abortWork = null } else { workAborted = true }
  } else if (command.type === "extension_ui_response" && waitingDialog === command.id) {
    waitingDialog = null
    answer(command.cancelled ? "dialog: cancelled" : "dialog: answered")
  } else if (command.type === "prompt") {
    const message = command.message
    if (message === "crash") process.exit(3)
    // Like the bm_* extensions' /bm-shutdown command: exit cleanly.
    if (message === "/bm-shutdown") process.exit(0)

    send({id: command.id, type: "response", command: "prompt", success: true})
    send({type: "agent_start"})
    send({type: "message_start", message: {role: "user", content: message}})
    send({type: "message_end", message: {role: "user", content: message}})

    if (message === "dialog") {
      waitingDialog = "ui-1"
      send({type: "extension_ui_request", id: "ui-1", method: "confirm", title: "Allow?", message: "Really?"})
    } else if (message === "bm-dialog" || message === "bm-bad") {
      waitingBm = "bm-1"
      const placeholder = message === "bm-dialog"
        ? JSON.stringify({v: 1, op: "submit_result", request_id: "req-1", payload: {status: "done", summary: "probe"}})
        : "not json"
      send({type: "extension_ui_request", id: "bm-1", method: "input", title: "bm:submit_result", placeholder})
    } else if (message === "nocost") {
      answer("no cost", "stop", undefined, false)
    } else if (message === "break-reset") {
      failNextReset = true
      answer("reset will fail")
    } else if (message === "report") {
      send({type: "extension_ui_request", id: "n-1", method: "notify", notifyType: "info",
            message: `bm:${JSON.stringify({event: "result", data: {status: "done", summary: "probe"}})}`})
      answer("reported")
    } else if (message === "spawn-child") {
      spawn("sleep", ["60"], {stdio: "ignore"}).unref()
      const script = 'printf "%s\\n" "$$" >> "$BM_PGID_FILE"; nohup sleep 60 >/dev/null 2>&1 &'
      spawn("sh", ["-c", script], {detached: true, stdio: "ignore"}).on("exit", () => answer("spawned"))
    } else if (message.startsWith("work:")) {
      runWork(JSON.parse(message.slice("work:".length)))
    } else if (message.startsWith("plan:")) {
      planWaves = JSON.parse(message.slice("plan:".length))
      runPlanWave(planWaves.shift() ?? {})
    } else if (message === "plan") {
      streamPlan()
    } else if (message === "fail") {
      answer("", "error", "boom")
    } else if (message.startsWith("tool")) {
      send({type: "tool_execution_start", toolCallId: "call-1", toolName: "read", args: {path: "mix.exs"}})
      send({type: "tool_execution_end", toolCallId: "call-1", toolName: "read", result: {content: []}, isError: false})
      answer("read mix.exs")
    } else {
      answer(`echo: ${message}`)
    }
  } else {
    send({id: command.id, type: "response", command: command.type, success: false, error: "unsupported"})
  }
}

// Like BM's extensions, report the profile at start: tools from --tools, guard if bm_guard is loaded.
const toolsArg = process.argv.indexOf("--tools")
if (toolsArg >= 0) {
  const tools = process.argv[toolsArg + 1].split(",").concat(process.env.FAKE_EXTRA_TOOL ? [process.env.FAKE_EXTRA_TOOL] : [])
  const role = tools.includes("propose_task") ? "planner" : "worker"
  const notify = data => send({type: "extension_ui_request", id: `r-${Math.random()}`, method: "notify", message: `bm:${JSON.stringify(data)}`})
  notify({event: "profile", data: {role, tools}})
  if (process.argv.some(arg => arg.endsWith("bm_guard.ts"))) notify({event: "guard", data: {tools: ["edit", "write", "bash"]}})
}

process.stdin.on("data", chunk => {
  buffer += chunk.toString("utf8")
  let index
  while ((index = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, index)
    buffer = buffer.slice(index + 1)
    if (line.trim()) handle(JSON.parse(line))
  }
})
process.stdin.on("end", () => process.exit(0))
// The agent may close the pipe while replies are still being written.
process.stdout.on("error", () => process.exit(0))
