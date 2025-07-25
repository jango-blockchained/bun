import { file, spawn } from "bun";
import { expect, it } from "bun:test";
import { bunEnv, bunExe } from "harness";
import { join } from "node:path";
it("should log to console correctly", async () => {
  const { stderr, exited } = spawn({
    cmd: [bunExe(), join(import.meta.dir, "console-timeLog.js")],
    stdin: null,
    stdout: "pipe",
    stderr: "pipe",
    env: bunEnv,
  });
  expect(await exited).toBe(0);
  const outText = await stderr.text();
  const expectedText = (await file(join(import.meta.dir, "console-timeLog.expected.txt")).text()).replaceAll(
    "\r\n",
    "\n",
  );

  expect(outText.replace(/^\[.+?s\] /gm, "")).toBe(expectedText.replace(/^\[.+?s\] /gm, ""));
});
