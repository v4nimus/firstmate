#!/usr/bin/env node
// Classify long shell sleeps issued by a Pi Firstmate primary.
//
// Pi supervision is extension-owned, so a primary must return control after
// ordinary work instead of occupying its only reasoning turn with a manual
// sleep/poll cycle. This policy reuses the repository's shell lexer and command
// position parser, inspects only executed command positions, and never evaluates
// submitted shell text. Static sleep durations at or above the configured limit
// are denied. Dynamic durations remain the shell's responsibility.

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Lexer, commandPosition, splitProgram } from "./fm-arm-command-policy.mjs";

function parseArguments(argv) {
  const result = { command: "", maxSeconds: 15 };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name === "--command" || name === "--max-seconds") {
      if (index + 1 >= argv.length) throw new Error(`${name} requires a value`);
      if (name === "--command") result.command = argv[index + 1];
      else result.maxSeconds = Number(argv[index + 1]);
      index += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  if (!Number.isFinite(result.maxSeconds) || result.maxSeconds <= 0) {
    throw new Error("--max-seconds must be a positive number");
  }
  return result;
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function durationSeconds(value) {
  const match = value.match(/^([0-9]+(?:\.[0-9]+)?)([smhd]?)$/);
  if (!match) return null;
  const units = { "": 1, s: 1, m: 60, h: 3600, d: 86400 };
  return Number(match[1]) * units[match[2]];
}

function shellPayload(position) {
  const command = basename(position.command?.value || "");
  if (!["bash", "sh", "zsh"].includes(command)) return "";
  const args = position.words.slice(position.index + 1);
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index].value;
    if (value === "-c" || value === "-lc" || value === "-cl") {
      return args[index + 1]?.literal ? args[index + 1].value : "";
    }
  }
  return "";
}

function classifyProgram(source, maxSeconds, depth = 0) {
  if (depth > 6) return null;
  const parsed = new Lexer(source).tokenize();
  if (parsed.error) return null;
  const program = splitProgram(parsed.tokens);

  for (const node of program.nodes) {
    for (const token of node) {
      if (token.type === "group") {
        const nested = classifyProgram(token.content, maxSeconds, depth + 1);
        if (nested) return nested;
      }
      if (token.type === "word") {
        for (const substitution of token.subs || []) {
          const nested = classifyProgram(substitution.content, maxSeconds, depth + 1);
          if (nested) return nested;
        }
      }
    }

    const position = commandPosition(node);
    if (!position.command) continue;
    for (const payload of position.wrapperPayloads || []) {
      const nested = classifyProgram(payload, maxSeconds, depth + 1);
      if (nested) return nested;
    }
    const payload = shellPayload(position);
    if (payload) {
      const nested = classifyProgram(payload, maxSeconds, depth + 1);
      if (nested) return nested;
    }

    const command = basename(position.command.value);
    if (command === "eval") {
      for (const word of position.words.slice(position.index + 1)) {
        if (!word.literal) continue;
        const nested = classifyProgram(word.value, maxSeconds, depth + 1);
        if (nested) return nested;
      }
      continue;
    }
    if (command !== "sleep") continue;

    let total = 0;
    let recognized = false;
    for (const word of position.words.slice(position.index + 1)) {
      if (!word.literal) {
        recognized = false;
        break;
      }
      const seconds = durationSeconds(word.value);
      if (seconds === null) {
        recognized = false;
        break;
      }
      recognized = true;
      total += seconds;
    }
    if (recognized && total >= maxSeconds) return total;
  }
  return null;
}

export function classifyPiPrimaryWait(command, maxSeconds = 15) {
  const duration = classifyProgram(command, maxSeconds);
  return duration === null
    ? { decision: "allow" }
    : { decision: "deny", reason: "pi-primary-long-wait", duration };
}

function main() {
  let args;
  try {
    args = parseArguments(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 2;
    return;
  }
  const result = classifyPiPrimaryWait(args.command, args.maxSeconds);
  if (result.decision === "allow") {
    process.stdout.write("allow\n");
    return;
  }
  process.stdout.write(`deny\t${result.reason}\t${result.duration}\n`);
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  main();
}
