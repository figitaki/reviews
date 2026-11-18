// The CLI sign-in page (ReviewsWeb.DeviceHTML): one box per letter of the
// code, and a countdown to when the code expires. Without JavaScript the
// boxes still submit; the server joins them.

// The letters of `text` that can be in a code, uppercased: a pasted
// "sqvd-llnp" gives "SQVDLLNP", and vowels, digits and dashes drop out.
export const codeChars = (text, alphabet) =>
  [...String(text).toUpperCase()].filter(char => alphabet.includes(char)).join("")

// "9:05" for 545 seconds; never below "0:00".
export const formatLeft = seconds => {
  const left = Math.max(0, Math.ceil(seconds))
  return `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`
}

const mountCodeBoxes = root => {
  const alphabet = root.dataset.alphabet
  const boxes = [...root.querySelectorAll("input")]
  const submit = root.form?.querySelector("[type=submit]")

  // Writes `chars` into the boxes from `start` on, then focuses the next
  // empty box, or the submit button once every box is filled.
  const fill = (start, chars) => {
    ;[...chars].slice(0, boxes.length - start).forEach((char, i) => {
      boxes[start + i].value = char
    })
    const next = boxes.findIndex((box, i) => i >= start && box.value === "")
    if (next >= 0) boxes[next].focus()
    else if (boxes.every(box => box.value)) submit?.focus()
    else boxes[Math.min(start + chars.length, boxes.length - 1)].focus()
  }

  boxes.forEach((box, index) => {
    box.addEventListener("focus", () => box.select())

    // Typing, and autofill that drops the whole code into one box.
    box.addEventListener("input", () => {
      const chars = codeChars(box.value, alphabet)
      box.value = ""
      if (chars) fill(index, chars)
    })

    // The whole code fills every box, wherever it is pasted.
    box.addEventListener("paste", event => {
      event.preventDefault()
      const chars = codeChars(event.clipboardData?.getData("text") ?? "", alphabet)
      if (chars) fill(chars.length >= boxes.length ? 0 : index, chars)
    })

    box.addEventListener("keydown", event => {
      if (event.key === "Backspace" && box.value === "" && index > 0) {
        event.preventDefault()
        boxes[index - 1].value = ""
        boxes[index - 1].focus()
      } else if (event.key === "ArrowLeft" && index > 0) {
        event.preventDefault()
        boxes[index - 1].focus()
      } else if (event.key === "ArrowRight" && index < boxes.length - 1) {
        event.preventDefault()
        boxes[index + 1].focus()
      }
    })
  })
}

// Counts down from the seconds the server rendered, by this page's clock,
// so a wrong clock on the phone doesn't matter. At zero it says so and
// turns off Allow.
const mountExpiry = el => {
  const deadline = performance.now() + Number(el.dataset.secondsLeft) * 1000
  const clock = el.querySelector("[data-countdown]")
  const expired = document.getElementById(el.dataset.expiredId)
  const approve = document.getElementById(el.dataset.approveId)

  const tick = () => {
    const left = (deadline - performance.now()) / 1000
    clock.textContent = formatLeft(left)
    el.classList.toggle("is-urgent", left <= 60)
    if (left > 0) return
    clearInterval(timer)
    el.hidden = true
    if (expired) expired.hidden = false
    if (approve) approve.disabled = true
  }

  const timer = setInterval(tick, 1000)
  tick()
}

export const mountDevicePage = () => {
  document.querySelectorAll("[data-device-code]").forEach(mountCodeBoxes)
  document.querySelectorAll("[data-device-expiry]").forEach(mountExpiry)
}
