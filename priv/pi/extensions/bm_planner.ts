/**
 * BM planner tools. Load only in the planner profile.
 *
 * `propose_plan` proposes the whole plan in one call (and may close it); `propose_task` adds or
 * re-proposes one task; the BEAM validates and accepts or rejects each task. The tool returns
 * the BEAM's decision, so the model only hears "accepted" when the BEAM persisted the task.
 * The streamed arguments of these calls may also be shown early in the UI, but they are never
 * treated as authorization.
 */

import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { bmRequest, registerShutdown, report } from "./bm_common.ts";

const taskFields = {
		key: Type.String({ description: "Stable unique key, lowercase with underscores, e.g. health_endpoint." }),
		title: Type.String({ description: "One-line title." }),
		goal: Type.String({ description: "What the worker must achieve, in two or three sentences." }),
		mutates: Type.Boolean({ description: "True if the task changes files; false for read-only analysis." }),
		writes: Type.Optional(
			Type.Array(Type.String(), { description: "Files the task will create or change (required when mutates is true)." }),
		),
		depends_on: Type.Optional(Type.Array(Type.String(), { description: "Keys of tasks that must be accepted first." })),
		done_when: Type.String({ description: "Concrete check that proves the task is complete." }),
		check: Type.Optional(
			Type.String({
				description:
					"Optional shell command BM runs after the task (after the verify command); it must exit 0 for the " +
					"task to be accepted. Use it to make done_when executable, e.g. `python3 test_shapes.py`.",
			}),
		),
};

const proposeTask = defineTool({
	name: "propose_task",
	label: "Propose task",
	description:
		"Add or re-propose ONE task (for the whole initial plan use propose_plan). BM validates it and replies " +
		"whether it was accepted. Keep each task small and self-contained: a worker sees only this task, not " +
		"the conversation.",
	parameters: Type.Object(taskFields),
	async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
		const reply = await bmRequest(ctx, "propose_task", params);
		const text =
			reply.status === "accepted"
				? `Task ${params.key} accepted by BM.`
				: `Task ${params.key} not accepted: ${String(reply.reason ?? reply.status)}`;
		return { content: [{ type: "text", text }], details: { key: params.key, status: reply.status } };
	},
});

const proposePlan = defineTool({
	name: "propose_plan",
	label: "Propose plan",
	description:
		"Propose the whole plan in ONE call: every task, in order (a task may depend on an earlier one in the " +
		"same list). BM validates them in order and replies per task. If the plan is complete, pass " +
		"close_summary: BM then also closes the plan, but only if every task was accepted; otherwise fix the " +
		"rejected ones with propose_task and call close_plan.",
	parameters: Type.Object({
		tasks: Type.Array(Type.Object(taskFields), { description: "The tasks, in dependency order." }),
		close_summary: Type.Optional(
			Type.String({ description: "One sentence describing the plan; closes it if every task is accepted." }),
		),
	}),
	async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
		const reply = await bmRequest(ctx, "propose_plan", params);
		const results = (reply.tasks as Array<{ key: string; status: string; reason?: string }>) ?? [];
		const lines = results.map((r) =>
			r.status === "accepted" ? `Task ${r.key} accepted.` : `Task ${r.key} not accepted: ${r.reason ?? r.status}`,
		);
		if (reply.closed === true) lines.push("Plan closed.");
		else if (params.close_summary) lines.push("Plan NOT closed: fix the rejected tasks, then call close_plan.");
		return { content: [{ type: "text", text: lines.join("\n") }], details: { results, closed: reply.closed === true } };
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
	pi.registerTool(proposePlan);
	pi.registerTool(proposeTask);
	pi.registerTool(closePlan);
	pi.on("session_start", (_event, ctx) => report(ctx, "profile", { role: "planner", tools: pi.getActiveTools() }));
}
