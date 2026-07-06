# klue
An idiomatic way to build simple, shareable dashboards fast

## Install
### Clone the repository
```sh
$ git clone https://github.com/bbusse/klue && cd klue
```
### Optionally: Get just the run script
```sh
$ curl -O https://raw.githubusercontent.com/bbusse/klue/refs/heads/dev/run
```

## Run from container
```sh
# Start with the example config
$ ./run klue-local-system.toml
```
## Run without container
```sh
# Start with the example config
$ ./klue --config klue-local-system.toml
```
## How does it work?
klue is data source agnostic - it does not care where the data comes from, it only presents data  
Getting the data is not in its responsibility  
  
At its core it uses [tmux](https://man.openbsd.org/tmux) with windows and panes to create a predefined layout and start predefined processes
in these windows / panes  
  
vju-t can be used to work on / manipulate the output custom commands produce by wrapping it  
Depending on the configuration it may show status indicators, charts, text, icons, emojis
## Developmemt
Contributions are welcome but may not be handled timely. Time is a sparse resource  
New functionality should come with tests  
[ShellCheck](https://github.com/koalaman/shellcheck) and [shfmt](https://github.com/mvdan/sh) (4 spaces) are used to check the code for formatting or code consistency and issues
### Create release candidate
```sh
$ make rc
```
### Create release
```sh
$ make release
```
## Resources
[vju-t](https://github.com/bbusse/vju-t)  
[tmux](https://man.openbsd.org/tmux)  
[The TTY demystified](https://www.linusakesson.net/programming/tty/)
