// Stand-in for `pi --mode rpc` in tests. Speaks the same JSONL protocol with scripted replies:
//   "tool ..."  -> runs a fake `read` tool, then answers
//   "fail"      -> the assistant message ends with an error
//   "dialog"    -> asks a confirm dialog and answers with how it was resolved
//   "crash"     -> exits with status 3
//   "report"    -> reports a result through a bm: notify record, as the bm_bridge extension does
//   "plan"      -> streams three add_task calls OpenAI-style (all toolcall_end events at the end)
//   anything    -> answers "echo: <message>"
let buffer = ""
let waitingDialog = null

const send = record => process.stdout.write(JSON.stringify(record) + "\n")
const usage = {input: 10, output: 2, cacheRead: 5, cacheWrite: 0, totalTokens: 17}

function answer(text, stopReason = "stop", errorMessage) {
  send({type: "message_start", message: {role: "assistant", content: [], stopReason: "pending"}})
  if (text) send({type: "message_update", usage, assistantMessageEvent: {type: "text_delta", contentIndex: 0, delta: text}})
  send({type: "message_end", message: {role: "assistant", stopReason, errorMessage}})
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

function handle(command) {
  if (command.type === "get_state") {
    send({id: command.id, type: "response", command: "get_state", success: true,
          data: {model: {id: "fake-model", name: "Fake Model"}, isStreaming: false,
                 // Echo the environment guard so tests can check it reached the process.
                 sessionName: process.env.PI_FABRIC_DEPTH ? `depth-${process.env.PI_FABRIC_DEPTH}` : undefined}})
  } else if (command.type === "new_session") {
    send({id: command.id, type: "response", command: "new_session", success: true, data: {cancelled: false}})
  } else if (command.type === "abort") {
    send({id: command.id, type: "response", command: "abort", success: true})
  } else if (command.type === "extension_ui_response" && waitingDialog === command.id) {
    waitingDialog = null
    answer(command.cancelled ? "dialog: cancelled" : "dialog: answered")
  } else if (command.type === "prompt") {
    const message = command.message
    if (message === "crash") process.exit(3)

    send({id: command.id, type: "response", command: "prompt", success: true})
    send({type: "agent_start"})
    send({type: "message_start", message: {role: "user", content: message}})
    send({type: "message_end", message: {role: "user", content: message}})

    if (message === "dialog") {
      waitingDialog = "ui-1"
      send({type: "extension_ui_request", id: "ui-1", method: "confirm", title: "Allow?", message: "Really?"})
    } else if (message === "report") {
      send({type: "extension_ui_request", id: "n-1", method: "notify", notifyType: "info",
            message: `bm:${JSON.stringify({event: "result", data: {status: "done", summary: "probe"}})}`})
      answer("reported")
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
