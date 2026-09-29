// Stand-in for `pi --mode rpc` in tests. Speaks the same JSONL protocol with scripted replies:
//   "tool ..."  -> runs a fake `read` tool, then answers
//   "fail"      -> the assistant message ends with an error
//   "dialog"    -> asks a confirm dialog and answers with how it was resolved
//   "crash"     -> exits with status 3
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

function handle(command) {
  if (command.type === "get_state") {
    send({id: command.id, type: "response", command: "get_state", success: true,
          data: {model: {id: "fake-model", name: "Fake Model"}, isStreaming: false}})
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
