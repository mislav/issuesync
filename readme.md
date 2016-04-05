# GitHub issues sync

A simple Ruby script that downloads all issues for the current GitHub project
to Markdown files for offline perusal.

```sh
$ gem install net-http-persistent
$ rake install [PREFIX=/usr/local]

$ cd /path/to/myproject
$ issuesync
# => downloads into individual `issues/*.md` files
```

You might quickly run into API rate limit if the project has many issues. To
avoid that, create a Personal Access Token in your GitHub settings and export
its value to an environment variable:

```sh
export GITHUB_TOKEN="..."
```

The `script/` directory contains per-project helper scripts to list latest
issues or to generate ctags for issue numbers.
