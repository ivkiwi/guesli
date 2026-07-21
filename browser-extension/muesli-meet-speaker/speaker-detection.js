(function installSpeakerDetection(root) {
  function normalizeName(value) {
    return String(value || "")
      .replace(/\s+/g, " ")
      .replace(/[,:;-]+$/g, "")
      .trim()
      .toLocaleLowerCase();
  }

  function participantNameMatches(candidate, participant) {
    const candidateName = normalizeName(candidate);
    const participantName = normalizeName(participant);
    if (!candidateName || !participantName) return false;
    if (candidateName === participantName) return true;

    const shorter = candidateName.length < participantName.length ? candidateName : participantName;
    const longer = candidateName.length < participantName.length ? participantName : candidateName;
    return shorter.length >= 5 && longer.startsWith(shorter);
  }

  function captionSpeakerFromLines(lines, participants) {
    if (!Array.isArray(lines) || lines.length < 1) return "";
    const firstLine = String(lines[0] || "").trim();
    if (!firstLine) return "";

    const matches = participants
      .map((participant) => typeof participant === "string" ? participant : participant?.name)
      .filter((name) => name && participantNameMatches(firstLine, name));
    if (matches.length !== 1) return "";

    const inlineSpeech = firstLine.slice(matches[0].length).trim();
    const speech = [inlineSpeech, ...lines.slice(1)].join(" ").trim();
    return speech.length >= 2 ? matches[0] : "";
  }

  function preferExplicitSpeakers(explicitSpeakers, captionSpeakers) {
    return Array.isArray(explicitSpeakers) && explicitSpeakers.length > 0
      ? explicitSpeakers
      : (Array.isArray(captionSpeakers) ? captionSpeakers : []);
  }

  const api = { participantNameMatches, captionSpeakerFromLines, preferExplicitSpeakers };
  root.MuesliMeetSpeakerDetection = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis === "undefined" ? this : globalThis);
