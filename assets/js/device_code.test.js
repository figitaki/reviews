import {test, expect} from "bun:test"
import {codeChars, formatLeft} from "./device_code"

const alphabet = "BCDFGHJKLMNPQRSTVWXZ"

test("codeChars keeps only the code's letters, uppercased", () => {
  expect(codeChars("sqvd-llnp", alphabet)).toBe("SQVDLLNP")
  expect(codeChars(" SQVD LLNP\n", alphabet)).toBe("SQVDLLNP")
  // Vowels and digits are never in a code.
  expect(codeChars("A1e2B", alphabet)).toBe("B")
  expect(codeChars("", alphabet)).toBe("")
})

test("formatLeft shows minutes and padded seconds, never below zero", () => {
  expect(formatLeft(600)).toBe("10:00")
  expect(formatLeft(545)).toBe("9:05")
  // A part second still counts, so 0:00 shows only once it has expired.
  expect(formatLeft(0.2)).toBe("0:01")
  expect(formatLeft(-3)).toBe("0:00")
})
