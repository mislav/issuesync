# GitHub issues sync

A simple Ruby script that downloads all issues for the current GitHub project
to Markdown files for offline perusal.

```
$ rake install [PREFIX=/usr/local]

$ cd /path/to/myproject
$ issuesync
# => downloads into individual `issues/*.md` files
```

The `script/` directory contains per-project helper scripts to list latest
issues or to generate ctags for issue numbers.
