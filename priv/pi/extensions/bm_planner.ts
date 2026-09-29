/**
 * BM planner tools. Load only in the planner profile.
 *
 * `propose_task` proposes work; the BEAM validates and accepts or rejects it. The tool returns
 * the BEAM's decision, so the model only hears "accepted" when the BEAM persisted the task.
 * The streamed arguments of these calls may also be shown early in the UI, but they are never
 * treated as authorization.
 */

import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { bmRequest, registerShutdown, report } from "./bm_common.ts";

const proposeTask = defineTool({
	name: "propose_task",
	label: "Propose task",
	description:
		"Propose one unit of work for a worker agent. BM validates it and replies whether it was accepted. " +
		"Call it once per task; you may propose several tasks in one response. Keep each task small and " +
		"self-contained: a worker sees only this task, not the conversation.",
	parameters: Type.Object({
		key: Type.String({ description: "Stable unique key, lowercase with underscores, e.g. health_endpoint." }),
		title: Type.String({ description: "One-line title." }),
		goal: Type.String({ description: "What the worker must achieve, in two or three sentences." }),
		mutates: Type.Boolean({ description: "True if the task changes files; false for read-only analysis." }),
		writes: Type.Optional(
			Type.Array(Type.String(), { description: "Files the task will create or change (required when mutates is true)." }),
		),
		depends_on: Type.Optional(Type.Array(Type.String(), { description: "Keys of tasks that must be accepted first." })),
		done_when: Type.String({ description: "Concrete check that proves the task is complete." }),
	}),
	async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
		const reply = await bmRequest(ctx, "propose_task", params);
		const text =
			reply.status === "accepted"
				? `Task ${params.key} accepted by BM.`
				: `Task ${params.key} not accepted: ${String(reply.reason ?? reply.status)}`;
		return { content: [{ type: "text", text }], details: { key: params.key, status: reply.status } };
	},
});

const closePlan = defineTool({
	name: "close_plan",
	label: "Close plan",
	description: "Tell BM that you have proposed every task for now. Call it once, after your last propose_task.",
	parameters: Type.Object({
		summary: Type.String({ description: "One or two sentences describing the plan." }),
	}),
	async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
		await bmRequest(ctx, "close_plan", params);
		return { content: [{ type: "text", text: "Plan closed." }], details: {} };
	},
});

export default function (pi: ExtensionAPI) {
	registerShutdown(pi);
	pi.registerTool(proposeTask);
	pi.registerTool(closePlan);
	pi.on("session_start", (_event, ctx) => report(ctx, "profile", { role: "planner", tools: pi.getActiveTools() }));
}
