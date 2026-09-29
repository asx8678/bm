import * as esbuild from "esbuild"
import path from "node:path"

const args = process.argv.slice(2)
const watch = args.includes("--watch")
const deploy = args.includes("--deploy")

const options = {
  entryPoints: ["js/app.js"],
  bundle: true,
  target: "es2022",
  outdir: "../priv/static/assets/js",
  logLevel: "info",
  sourcemap: watch ? "inline" : false,
  minify: deploy,
  external: ["/fonts/*", "/images/*"],
  alias: {"@": "."},
  // phoenix-colocated (LiveView colocated hooks) is generated into _build/<env>.
  nodePaths: [path.resolve("../_build", deploy ? "prod" : process.env.MIX_ENV || "dev")],
  define: {"process.env.NODE_ENV": JSON.stringify(deploy ? "production" : "development")},
}

if (watch) {
  const context = await esbuild.context(options)
  await context.watch()
  // Exit when Phoenix closes stdin, so the watcher does not outlive the server.
  process.stdin.on("close", () => process.exit(0))
  process.stdin.resume()
} else {
  await esbuild.build(options)
}
