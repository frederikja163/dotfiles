import type { Todo } from "./schema"

export type TodoCounts = {
  total: number
  completed: number
  in_progress: number
  pending: number
  cancelled: number
}

export function countTodos(todos: readonly Todo[]): TodoCounts {
  return {
    total: todos.length,
    completed: todos.filter((todo) => todo.status === "completed").length,
    in_progress: todos.filter((todo) => todo.status === "in_progress").length,
    pending: todos.filter((todo) => todo.status === "pending").length,
    cancelled: todos.filter((todo) => todo.status === "cancelled").length,
  }
}

export function formatTodos(todos: readonly Todo[]) {
  const counts = countTodos(todos)
  const header = `Todos ${counts.completed}/${counts.total} completed`
  if (todos.length === 0) return `${header}\n(empty)`
  return [header, ...todos.map(formatTodo)].join("\n")
}

function formatTodo(todo: Todo) {
  const marker =
    todo.status === "completed"
      ? "[x]"
      : todo.status === "in_progress"
        ? "[>]"
        : todo.status === "cancelled"
          ? "[-]"
          : "[ ]"
  const current = todo.activeForm ? ` currently: ${todo.activeForm}` : ""
  return `${marker} (${todo.priority}) ${todo.content}${current}`
}
