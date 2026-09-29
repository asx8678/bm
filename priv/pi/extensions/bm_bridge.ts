/**
 * BM bridge: model-facing tools that the BEAM orchestrator acts on.
 *
 * The tools do no work themselves; the BEAM acts on them. It learns about a call in two ways:
 * - streamed argument deltas (toolcall_start/delta/end), so a planner's tasks can start while
 *   it is still writing the rest of its plan;
 * - a `bm:`-prefixed notify record written to pi's RPC output when the tool executes. Pi Fabric's
 *   code mode runs extension tools as nested calls that emit no events of their own, so this is
 *   the only channel that works both for direct calls and from inside fabric_exec.
 */

import { StringEnum, Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";

const report = (ctx: ExtensionContext | undefined, event: string, data: unknown) =>
	ctx?.ui?.notify(`bm:${JSON.stringify({ event, data })}`, "info");

const addTask = defineTool({
	name: "add_task",
	label: "Add task",
	description:
		"Register one independent unit of work for a worker agent. Call it once per task, " +
		"and register all tasks in the same response. Keep each task small and self-contained: " +
		"a worker only sees this task, not the conversation.",
	parameters: Type.Object({
		id: Type.String({ description: "Short unique id, lowercase with underscores, e.g. health_endpoint." }),
		title: Type.String({ description: "One-line title." }),
		goal: Type.String({ description: "What the worker must achieve, in two or three sentences." }),
		files: Type.Optional(Type.Array(Type.String(), { description: "Files the worker will likely touch." })),
		depends_on: Type.Optional(Type.Array(Type.String(), { description: "Ids of tasks that must finish first." })),
		done_when: Type.String({ description: "Concrete check that proves the task is complete." }),
	}),
	async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
		report(ctx, "task", params);
		return {
			content: [{ type: "text", text: `Task ${params.id} queued.` }],
			details: { id: params.id },
		};
	},
});

const submitResult = defineTool({
	name: "submit_result",
	label: "Submit result",
	description: "Report the outcome of your assigned task. Call it exactly once, as your last action.",
	parameters: Type.Object({
		status: StringEnum(["done", "blocked", "failed"] as const),
		summary: Type.String({ description: "What you changed or found, in at most five sentences." }),
		files_changed: Type.Optional(Type.Array(Type.String())),
	}),
	async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
		report(ctx, "result", params);
		return {
			content: [{ type: "text", text: "Result recorded." }],
			details: { status: params.status },
			// The worker has nothing left to do after reporting.
			terminate: true,
		};
	},
});

export default function (pi: ExtensionAPI) {
	pi.registerTool(addTask);
	pi.registerTool(submitResult);
}
