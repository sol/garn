import { hasTag } from "./internal/utils.ts";
import { NixExpression } from "./nix.ts";

/**
 * `Executable`s are commands (usually shell snippets) that are being run on
 * your local machine (not in a sandbox).
 *
 * They are based on an underlying `Environment`, and can make use of e.g. the
 * executables that that `Environment` provides.
 *
 * You can use `Executables` for a variety of purposes:
 *   - Running your projects main executable during development,
 *   - Running a code formatter,
 *   - Running a code generator,
 *   - Spinning up a database for development,
 *   - etc.
 *
 * You can run `Executable`s with `garn run`.
 */
export type Executable = {
  tag: "executable";
  nixExpression: NixExpression;

  /**
   * The executable description is rendered in the executable list when running `garn run`.
   */
  description: string;
};

export function isExecutable(e: unknown): e is Executable {
  return hasTag(e, "executable");
}

/**
 * Create an executable from a nix expression.
 *
 * This is a fairly low-level function. You may want to use `garn.shell`.
 */
export function mkExecutable(
  nixExpression: NixExpression,
  description: string,
): Executable {
  return {
    tag: "executable",
    nixExpression,
    description,
  };
}
