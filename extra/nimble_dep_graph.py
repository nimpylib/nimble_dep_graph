from __future__ import annotations

import argparse
import json
import logging
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import networkx as nx
import requests
from pydantic import BaseModel, Field

LOGGER = logging.getLogger(__name__)


NIMBLE_DEP_PATTERN = re.compile(r'^\s*pylib\s+"([^"]+)"\s*,\s*"([^"]+)"')

DEF_PACKAGE = "nimpylib/nimpylib"
DEF_ORG = "nimpylib/"
def simplify(repo: str) -> str:
  return repo.removeprefix(DEF_ORG)

class DependencySpec(BaseModel):
	repo: str
	version: str
	source_file: str


class RepoMetadata(BaseModel):
	repo: str
	nimble_file: str | None = None
	deps: list[DependencySpec] = Field(default_factory=list)


@dataclass
class GitHubClient:
	token: str | None = None
	timeout: int = 20

	def _headers(self) -> dict[str, str]:
		headers = {
			"Accept": "application/vnd.github+json",
			"User-Agent": "draw-nimble-dep",
		}
		if self.token:
			headers["Authorization"] = f"Bearer {self.token}"
		return headers

	def get_json(self, url: str) -> Any:
		response = requests.get(url, headers=self._headers(), timeout=self.timeout)
		response.raise_for_status()
		return response.json()

	def get_text(self, url: str) -> str:
		response = requests.get(url, headers=self._headers(), timeout=self.timeout)
		response.raise_for_status()
		return response.text


def validate_repo(repo: str) -> str:
	trimmed = repo.strip().strip("/")
	parts = trimmed.split("/")
	if len(parts) != 2 or not parts[0] or not parts[1]:
		raise ValueError(
			f"Invalid repo '{repo}'. Expected format 'owner/name', e.g. {DEF_PACKAGE}."
		)
	return f"{parts[0]}/{parts[1]}"


def normalize_dep_repo(dep_value: str, owner: str) -> str:
	dep = dep_value.strip().strip("/")
	if not dep:
		raise ValueError("Dependency name is empty in nimble metadata.")
	if '/' in dep:
		return validate_repo(dep)
	return f"{owner}/{dep}"


def parse_pylib_deps(nimble_text: str, current_repo: str, source_file: str) -> list[DependencySpec]:
	owner = current_repo.split("/")[0]
	deps: list[DependencySpec] = []

	for raw_line in nimble_text.splitlines():
		match = NIMBLE_DEP_PATTERN.match(raw_line)
		if match is None:
			continue

		dep_name, version = match.groups()
		dep_repo = normalize_dep_repo(dep_name, owner)
		deps.append(
			DependencySpec(repo=dep_repo, version=version.strip(), source_file=source_file)
		)

	return deps


def find_nimble_file(client: GitHubClient, repo: str) -> str | None:
	api = f"https://api.github.com/repos/{repo}/contents"
	payload = client.get_json(api)
	if not isinstance(payload, list):
		LOGGER.debug("GitHub contents payload for %s is not a list.", repo)
		return None

	for item in payload:
		if not isinstance(item, dict):
			continue
		item_type = item.get("type")
		name = item.get("name")
		download_url = item.get("download_url")
		if item_type == "file" and isinstance(name, str) and name.endswith(".nimble"):
			if isinstance(download_url, str):
				LOGGER.debug("Found nimble file for %s: %s", repo, name)
				return download_url

	LOGGER.info("No .nimble file found in repo root: %s", repo)
	return None


def _select_local_nimble_file(pkg_dir: Path, repo_name: str) -> Path | None:
	preferred = pkg_dir / f"{repo_name}.nimble"
	if preferred.exists() and preferred.is_file():
		return preferred

	nimble_files = sorted(path for path in pkg_dir.glob("*.nimble") if path.is_file())
	if nimble_files:
		return nimble_files[0]

	return None


def find_local_nimble_file(pkgs2_dir: Path, repo: str) -> Path | None:
	repo_name = repo.split("/", maxsplit=1)[1]
	if not pkgs2_dir.exists() or not pkgs2_dir.is_dir():
		LOGGER.debug("Local pkgs2 dir does not exist: %s", pkgs2_dir)
		return None

	candidates = [path for path in pkgs2_dir.glob(f"{repo_name}-*") if path.is_dir()]
	if not candidates:
		LOGGER.debug("No local pkgs2 match for %s under %s", repo, pkgs2_dir)
		return None

	# Prefer the most recently modified package directory when multiple hashes exist.
	candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)

	for candidate in candidates:
		nimble_path = _select_local_nimble_file(candidate, repo_name)
		if nimble_path is not None:
			LOGGER.info("Using local nimble metadata for %s: %s", repo, nimble_path)
			return nimble_path

	LOGGER.info("Matched local dirs for %s but found no .nimble file", repo)
	return None


def fetch_repo_metadata(client: GitHubClient, repo: str, pkgs2_dir: Path | None) -> RepoMetadata:
	if pkgs2_dir is not None:
		local_nimble_path = find_local_nimble_file(pkgs2_dir, repo)
		if local_nimble_path is not None:
			nimble_text = local_nimble_path.read_text(encoding="utf-8")
			deps = parse_pylib_deps(nimble_text, repo, local_nimble_path.name)
			LOGGER.info("Parsed %d direct deps from local %s", len(deps), local_nimble_path)
			return RepoMetadata(repo=repo, nimble_file=str(local_nimble_path), deps=deps)

	nimble_url = find_nimble_file(client, repo)
	if nimble_url is None:
		LOGGER.info("Skipping deps parse for %s because no nimble file was found.", repo)
		return RepoMetadata(repo=repo, nimble_file=None, deps=[])

	nimble_text = client.get_text(nimble_url)
	file_name = nimble_url.rsplit("/", maxsplit=1)[-1]
	deps = parse_pylib_deps(nimble_text, repo, file_name)
	LOGGER.info("Parsed %d direct deps from %s/%s", len(deps), repo, file_name)
	return RepoMetadata(repo=repo, nimble_file=file_name, deps=deps)


def crawl_dependency_graph(
	client: GitHubClient,
	entry_repos: list[str],
	max_repos: int,
	pkgs2_dir: Path | None,
) -> tuple[nx.DiGraph, dict[str, RepoMetadata], dict[str, str]]:
	graph = nx.DiGraph()
	metadata: dict[str, RepoMetadata] = {}
	errors: dict[str, str] = {}
	visited: set[str] = set()

	def visit(repo: str, depth: int = 0) -> None:
		if repo in visited:
			return
		if len(visited) >= max_repos:
			LOGGER.warning("Reached --max-repos limit (%d). Stopping recursion.", max_repos)
			return

		LOGGER.info("Visiting repo: %s (depth=%d)", repo, depth)
		visited.add(repo)
		graph.add_node(repo)

		try:
			repo_meta = fetch_repo_metadata(client, repo, pkgs2_dir)
			metadata[repo] = repo_meta
		except requests.exceptions.RequestException as exc:
			errors[repo] = f"Network/API error: {exc}"
			LOGGER.warning("Failed to fetch %s: %s", repo, errors[repo])
			return
		except OSError as exc:
			errors[repo] = f"Local file error: {exc}"
			LOGGER.warning("Failed to read local metadata for %s: %s", repo, errors[repo])
			return
		except ValueError as exc:
			errors[repo] = f"Parse error: {exc}"
			LOGGER.warning("Failed to parse %s: %s", repo, errors[repo])
			return

		for dep in repo_meta.deps:
			graph.add_edge(repo, dep.repo, version=dep.version, source_file=dep.source_file)
			visit(dep.repo, depth + 1)

	for entry_repo in entry_repos:
		visit(entry_repo)

	return graph, metadata, errors


def to_mermaid(graph: nx.DiGraph) -> str:
	lines = ["graph TD"]
	for source, target in graph.edges():
		source = simplify(source)
		target = simplify(target)

		lines.append(f'  {source} --> {target}')
	if graph.number_of_edges() == 0:
		for node in graph.nodes():
			node = simplify(node)
			lines.append(f'  {node}')
	return "\n".join(lines) + "\n"


def to_dot(graph: nx.DiGraph) -> str:
	lines = ["digraph deps {"]
	lines.append("  rankdir=LR;")
	for node in graph.nodes():
		lines.append(f'  "{node}";')
	for source, target, data in graph.edges(data=True):
		version = data.get("version", "")
		if version:
			lines.append(f'  "{source}" -> "{target}" [label="{version}"];')
		else:
			lines.append(f'  "{source}" -> "{target}";')
	lines.append("}")
	return "\n".join(lines) + "\n"


def write_outputs(
	output_dir: Path,
	entry_repos: list[str],
	graph: nx.DiGraph,
	metadata: dict[str, RepoMetadata],
	errors: dict[str, str],
	render_svg: bool,
) -> None:
	output_dir.mkdir(parents=True, exist_ok=True)

	json_path = output_dir / "deps.graph.json"
	dot_path = output_dir / "deps.graph.dot"
	mermaid_path = output_dir / "deps.graph.mmd"
	svg_path = output_dir / "deps.graph.svg"

	payload = {
		"entry_repos": entry_repos,
		"entry_repo": entry_repos[0] if entry_repos else None,
		"summary": {
			"nodes": graph.number_of_nodes(),
			"edges": graph.number_of_edges(),
			"errors": len(errors),
		},
		"repos": {repo: metadata_item.model_dump() for repo, metadata_item in metadata.items()},
		"edges": [
			{
				"from": source,
				"to": target,
				"version": data.get("version", ""),
				"source_file": data.get("source_file", ""),
			}
			for source, target, data in graph.edges(data=True)
		],
		"errors": errors,
	}

	json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
	dot_path.write_text(to_dot(graph), encoding="utf-8")
	mermaid_path.write_text(to_mermaid(graph), encoding="utf-8")

	if render_svg:
		try:
			subprocess.run(
				["dot", "-Tsvg", str(dot_path), "-o", str(svg_path)],
				check=True,
				capture_output=True,
				text=True,
			)
			LOGGER.info("Rendered SVG graph to %s", svg_path)
		except FileNotFoundError:
			LOGGER.warning("Graphviz 'dot' is not installed; skipped SVG render.")
		except subprocess.CalledProcessError as exc:
			stderr = exc.stderr.strip() if exc.stderr else "unknown error"
			LOGGER.warning("Graphviz render failed: %s", stderr)


def build_arg_parser() -> argparse.ArgumentParser:
	parser = argparse.ArgumentParser(
		description="Crawl GitHub repos via .nimble pylib deps and generate dependency graph files."
	)
	parser.add_argument(
		"entry_repos",
		nargs="*",
		default=[DEF_PACKAGE],
		help=f"Entry GitHub repos (owner/name). Default: {DEF_PACKAGE}",
	)
	parser.add_argument(
		"--max-repos",
		type=int,
		default=200,
		help="Maximum number of repos to crawl. Default: 200",
	)
	parser.add_argument(
		"--token",
		default=os.getenv("GITHUB_TOKEN"),
		help="GitHub token (or use GITHUB_TOKEN env var).",
	)
	parser.add_argument(
		"--output-dir",
		default="./out",
		help="Output directory for graph files. Default: ./out",
	)
	parser.add_argument(
		"--no-svg",
		action="store_true",
		help="Disable Graphviz SVG rendering.",
	)
	parser.add_argument(
		"--log-level",
		default="INFO",
		choices=["DEBUG", "INFO", "WARNING", "ERROR"],
		help="Logging level. Default: INFO",
	)
	parser.add_argument(
		"--nimble-pkgs2-dir",
		default=str(Path.home() / ".nimble" / "pkgs2"),
		help="Local nimble cache dir. Default: ~/.nimble/pkgs2",
	)
	parser.add_argument(
		"--no-local-pkgs2",
		action="store_true",
		help="Disable reading metadata from local ~/.nimble/pkgs2 cache.",
	)
	return parser


def main() -> int:
	parser = build_arg_parser()
	args = parser.parse_args()

	logging.basicConfig(
		level=getattr(logging, args.log_level),
		format="%(levelname)s %(message)s",
	)

	try:
		entry_repos = [validate_repo(repo) for repo in args.entry_repos]
		if not entry_repos:
			raise ValueError("At least one entry repo is required")
		if args.max_repos <= 0:
			raise ValueError("--max-repos must be > 0")
	except ValueError as exc:
		parser.error(str(exc))
		return 2

	pkgs2_dir: Path | None
	if args.no_local_pkgs2:
		pkgs2_dir = None
	else:
		pkgs2_dir = Path(args.nimble_pkgs2_dir).expanduser()
		LOGGER.info("Local pkgs2 metadata enabled: %s", pkgs2_dir)

	client = GitHubClient(token=args.token)
	graph, metadata, errors = crawl_dependency_graph(
		client=client,
		entry_repos=entry_repos,
		max_repos=args.max_repos,
		pkgs2_dir=pkgs2_dir,
	)

	output_dir = Path(args.output_dir)
	write_outputs(
		output_dir=output_dir,
		entry_repos=entry_repos,
		graph=graph,
		metadata=metadata,
		errors=errors,
		render_svg=not args.no_svg,
	)

	print(f"Entry repos: {', '.join(entry_repos)}")
	print(f"Graph nodes: {graph.number_of_nodes()}")
	print(f"Graph edges: {graph.number_of_edges()}")
	print(f"Errors: {len(errors)}")
	print(f"Outputs: {output_dir.resolve()}")
	if errors:
		print("\n[WARN] Repos with errors:")
		for repo, message in sorted(errors.items()):
			print(f"  - {repo}: {message}")

	return 0


if __name__ == "__main__":
	raise SystemExit(main())
