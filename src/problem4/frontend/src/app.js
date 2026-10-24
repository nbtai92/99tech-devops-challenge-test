// Runtime config is written per environment at deploy time (config.json),
// so the same build can be promoted from staging to production unchanged.
async function main() {
  const message = document.getElementById("message");
  try {
    const config = await (await fetch("/config.json", { cache: "no-store" })).json();
    document.getElementById("version").textContent = `version ${config.version}`;
    const res = await fetch(`${config.apiBaseUrl}/api/hello`);
    message.textContent = (await res.json()).message;
  } catch (err) {
    message.textContent = "Backend unavailable";
    console.error(err);
  }
}

main();
