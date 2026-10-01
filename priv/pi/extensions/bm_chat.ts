/**
 * BM chat planning tools (plan 32). Load only in the chat profile.
 *
 * The chat model makes and changes a plan of the user's repository through these tools; the
 * BEAM (Bm.Chat, Bm.Plans) checks and stores every change and shows it on the plan board. The
 * model reads the reply, so it only hears "done" when the BEAM stored the change. Nothing here
 * changes files or runs tasks.
 */

import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { bmRequest, registerShutdown, report } from "./bm_common.ts";

const content = {
	title: Type.Optional(Type.String({ description: "One-line title." })),
	why: Type.Optional(Type.String({ description: "Why the task is needed, for the user's goal." })),
	existing: Type.Optional(
		Type.String({ description: "What already exists in the code for this (files, functions, behaviour you read)." }),
	),
	approach: Type.Optional(Type.String({ description: "How to do it, concretely, in a few sentences." })),
	files: Type.Optional(Type.Array(Type.String(), { description: "Files it will create or change, relative paths." })),
	done_when: Type.Optional(Type.String({ description: "Concrete, checkable conditions for done, including edge cases." })),
	depends_on: Type.Optional(Type.Array(Type.String(), { description: "Keys of tasks that must be done first." })),
	risks: Type.Optional(Type.String({ description: "What could go wrong or break." })),
	open_questions: Type.Optional(
		Type.Array(Type.String(), { description: "Questions still open for the user about this task." }),
	),
	check: Type.Optional(Type.String({ description: "Optional shell command that proves it is done, e.g. `mix test test/x_test.exs`." })),
};

function reply(text: string, details: unknown = {}) {
	return { content: [{ type: "text" as const, text }], details };
}

function outcome(r: Record<string, unknown>, done: string) {
	return r.ok === true ? `${done}\n\n${String(r.plan ?? "")}`.trim() : `Not done: ${String(r.error ?? "refused")}`;
}

const createPlan = defineTool({
	name: "create_plan",
	label: "Create plan",
	description:
		"Start a new plan for the user's request (it becomes the current plan shown next to the chat). Do this after " +
		"you looked at the code. Then add its tasks with add_task.",
	parameters: Type.Object({
		title: Type.String({ description: "Short name of the plan, e.g. 'CSV export'." }),
		goal: Type.String({ description: "The user's goal, in their words, made precise." }),
		findings: Type.String({ description: "What you found in the code that matters for this plan." }),
	}),
	async execute(_id, params, _signal, _onUpdate, ctx) {
		const r = await bmRequest(ctx, "create_plan", params);
		return reply(outcome(r, `Plan "${params.title}" created; it is the current plan.`), r);
	},
});

const updatePlan = defineTool({
	name: "update_plan",
	label: "Update plan",
	description:
		"Change what the current plan says (only the fields you pass change). Use `scope` to write down the scope of " +
		"work you settled with the user: in scope, out of scope, assumptions.",
	parameters: Type.Object({
		title: Type.Optional(Type.String({ description: "Short name of the plan." })),
		goal: Type.Optional(Type.String({ description: "The user's goal, made precise." })),
		findings: Type.Optional(Type.String({ description: "What you found in the code that matters for this plan." })),
		scope: Type.Optional(
			Type.String({
				description: "Short lines under the headings 'In scope:', 'Out of scope:' and 'Assumptions:'.",
			}),
		),
	}),
	async execute(_id, params, _signal, _onUpdate, ctx) {
		const r = await bmRequest(ctx, "update_plan", params);
		return reply(outcome(r, "Plan updated."), r);
	},
});

const addTask = defineTool({
	name: "add_task",
	label: "Add task",
	description:
		"Add a task to the current plan. Fill every field you can: the user reads tasks before anything runs, so " +
		"why, what exists, approach, files and done_when matter. Keep tasks small; order them with depends_on.",
	parameters: Type.Object({
		key: Type.String({ description: "Stable key, snake_case, e.g. csv_endpoint." }),
		...content,
		title: Type.String({ description: "One-line title." }),
		before: Type.Optional(Type.String({ description: "Key of the task to insert this one before; default at the end." })),
	}),
	async execute(_id, params, _signal, _onUpdate, ctx) {
		const r = await bmRequest(ctx, "add_task", params);
		return reply(outcome(r, `Task ${params.key} added.`), r);
	},
});

const updateTask = defineTool({
	name: "update_task",
	label: "Update task",
	description: "Change fields of a task of the current plan (only the fields you pass change).",
	parameters: Type.Object({ key: Type.String({ description: "The task's key." }), ...content }),
	async execute(_id, params, _signal, _onUpdate, ctx) {
		const r = await bmRequest(ctx, "update_task", params);
		return reply(outcome(r, `Task ${params.key} updated.`), r);
	},
});

const removeTask = defineTool({
	name: "remove_task",
	label: "Remove task",
	description: "Remove a task from the current plan (refused while another task depends on it).",
	parameters: Type.Object({ key: Type.String({ description: "The task's key." }) }),
	async execute(_id, params, _signal, _onUpdate, ctx) {
		const r = await bmRequest(ctx, "remove_task", params);
		return reply(outcome(r, `Task ${params.key} removed.`), r);
	},
});

const getPlan = defineTool({
	name: "get_plan",
	label: "Get plan",
	description: "Read the current plan with all its tasks (the user may have changed it on the board).",
	parameters: Type.Object({}),
	async execute(_id, params, _signal, _onUpdate, ctx) {
		const r = await bmRequest(ctx, "get_plan", params);
		return reply(r.ok === true ? String(r.plan) : `No plan: ${String(r.error ?? "none")}`, r);
	},
});

const askUser = defineTool({
	name: "ask_user",
	label: "Ask the user",
	description:
		"Ask the user questions you need answered before you plan or change a task. They appear as cards in the " +
		"chat; the answers come back as the user's next message. After calling it, stop and wait.",
	parameters: Type.Object({
		questions: Type.Array(
			Type.Object({
				question: Type.String({ description: "One clear question." }),
				options: Type.Optional(Type.Array(Type.String(), { description: "Likely answers to pick from, if any." })),
			}),
			{ description: "One to five questions." },
		),
	}),
	async execute(_id, params, _signal, _onUpdate, ctx) {
		const r = await bmRequest(ctx, "ask_user", params);
		return reply(r.ok === true ? "The questions are shown to the user. Stop now and wait for the answers." : `Not shown: ${String(r.error)}`, r);
	},
});

export default function (pi: ExtensionAPI) {
	registerShutdown(pi);
	for (const tool of [createPlan, updatePlan, addTask, updateTask, removeTask, getPlan, askUser]) pi.registerTool(tool);
	pi.on("session_start", (_event, ctx) => report(ctx, "profile", { role: "chat", tools: pi.getActiveTools() }));
}
