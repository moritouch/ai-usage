(() => {
  "use strict";

  const root = document.documentElement;
  const configuredRepository = root.dataset.repository.trim();

  function inferRepository() {
    if (configuredRepository) return configuredRepository;
    if (!window.location.hostname.endsWith(".github.io")) return null;

    const owner = window.location.hostname.slice(0, -".github.io".length);
    const pathParts = window.location.pathname.split("/").filter(Boolean);
    const repository = pathParts[0] || `${owner}.github.io`;
    return owner && repository ? `${owner}/${repository}` : null;
  }

  const repository = inferRepository();
  if (!repository) return;

  const repositoryURL = `https://github.com/${repository}`;
  const releasesURL = `${repositoryURL}/releases`;
  const latestReleaseURL = `${releasesURL}/latest`;
  const issuesURL = `${repositoryURL}/issues`;

  document.querySelectorAll(".repository-link").forEach((link) => {
    link.href = repositoryURL;
  });
  document.querySelectorAll(".release-link").forEach((link) => {
    link.href = latestReleaseURL;
  });
  document.querySelectorAll(".checksum-link").forEach((link) => {
    link.href = latestReleaseURL;
  });
  document.querySelectorAll(".issues-link").forEach((link) => {
    link.href = issuesURL;
  });
  document.querySelectorAll(".security-link").forEach((link) => {
    link.href = `${repositoryURL}/blob/main/SECURITY.md`;
  });

  const releaseStatus = document.querySelector("#release-status");
  fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
    headers: { Accept: "application/vnd.github+json" }
  })
    .then((response) => {
      if (!response.ok) throw new Error("No published release");
      return response.json();
    })
    .then((release) => {
      if (typeof release.html_url === "string") {
        document.querySelectorAll(".release-link, .checksum-link").forEach((link) => {
          link.href = release.html_url;
        });
      }
      if (releaseStatus && typeof release.tag_name === "string") {
        releaseStatus.textContent = `${release.tag_name} · macOS 14以降 · Developer ID署名・Apple公証済みDMG`;
      }
    })
    .catch(() => {
      document.querySelectorAll(".release-link, .checksum-link").forEach((link) => {
        link.href = releasesURL;
      });
      if (releaseStatus) {
        releaseStatus.textContent = "現在の配布状況はGitHub Releasesで確認してください。";
      }
    });
})();
