# 99Tech DevOps Challenge

Solutions to the [99Tech DevOps Challenge](https://github.com/99techteam/devops-challenge).

## Solutions

| Problem | Topic | Entry point | Status |
| --- | --- | --- | --- |
| 1 | Building Castle In The Cloud | [Solution](src/problem1/SOLUTION.md) | Completed |
| 2 | Diagnose Me Doctor | [Solution](src/problem2/SOLUTION.md) | Completed |
| 3 | Debugging issues within system | [Starter instructions](src/problem3/README.md) | Not started |
| 4 | Ship It Twice | [Solution](src/problem4/SOLUTION.md) | Not started |
| 5 | Fortify The Castle | [Solution](src/problem5/SOLUTION.md) | Not started |

## Repository structure

```text
src/
├── problem1/    # Cloud architecture
├── problem2/    # Diagnosis
├── problem3/    # Supplied debugging application
├── problem4/    # Delivery workflows
└── problem5/    # Security
```

Each completed solution will describe its assumptions, approach, validation,
and known limitations. Problem-specific setup instructions belong alongside
that solution.

## Starter source

The `src/` skeleton comes from
[99techteam/devops-challenge](https://github.com/99techteam/devops-challenge/tree/d514e60a76ffb2bce8eaf1cc70e77de213aef597/src),
commit `d514e60a76ffb2bce8eaf1cc70e77de213aef597`.
The supplied application and configuration files are preserved for the challenge;
they have not yet been fixed or validated as a working deployment.

The upstream empty `src/problem3/.env` is ignored by Git. An empty
`.env.example` is included so a fresh clone can recreate it from the repository root:

```sh
cp src/problem3/.env.example src/problem3/.env
```

Problem 4 retains the upstream `src/problem4/.github/workflows/` placeholder.
GitHub Actions discovers executable workflows in the repository-root
`.github/workflows/` directory; workflow placement will be addressed in that solution.

## Submission

Browse the solutions using the links above. Any required runtime setup and
verification steps will be documented within the relevant problem directory.
