package App::shcompgen;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any::IfLOG '$log';

use File::Slurp::Tiny qw(read_file write_file);
use Perinci::Object;
use Perinci::Sub::Util qw(err);

our %SPEC;

my $re_progname = qr/\A[A-Za-z0-9_.,:-]+\z/;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Generate shell completion scripts',
};

our @supported_shells = qw(bash); # XXX fish tcsh zsh
our %common_args = (
    shell => {
        summary => 'Override autodetection and select shell manually',
        schema => ['str*', {in=>\@supported_shells}],
        description => <<'_',

The default is to look at your SHELL environment variable value. If it is
undefined, the default is `bash`.

_
    },
    global => {
        summary => 'Use global completions directory',
        schema => ['bool*'],
        cmdline_aliases => {
            per_user => {
                is_flag => 1,
                code    => sub { $_[0]{global} = 0 },
                summary => 'Alias for --no-global',
            },
        },
        description => <<'_',

Shell has global (system-wide) completions directory as well as per-user. For
example, in fish the global directory is by default `/etc/fish/completions` and
the per-user directory is `~/.config/fish/completions`.

By default, if running as root, the global is chosen. And if running as normal
user, per-user directory is chosen. Using `--global` or `--per-user` overrides
that and manually select which.

_
    },

    bash_global_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        default => ['/usr/share/bash-completion/completions',
                    '/etc/bash_completion.d'],
    },
    bash_per_user_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
    },

    #fish_global_dir => {
    #    summary => 'Directory to put completions scripts',
    #    schema  => ['array*', of => 'str*'],
    #    default => ['/usr/share/fish/completions', '/etc/fish/completions'],
    #},
    #fish_per_user_dir => {
    #    summary => 'Directory to put completions scripts',
    #    schema  => ['array*', of => 'str*'],
    #},

    #tcsh_global_dir => {
    #    summary => 'Directory to put completions scripts',
    #    schema  => ['array*', of => 'str*'],
    #    default => '/etc/fish/completions',
    #},
    #tcsh_per_user_dir => {
    #    summary => 'Directory to put completions scripts',
    #    schema  => ['array*', of => 'str*'],
    #},

    #zsh_global_dir => {
    #    summary => 'Directory to put completions scripts',
    #    schema  => ['array*', of => 'str*'],
    #    schema  => 'str*',
    #    default => [],
    #},
    #zsh_per_user_dir => {
    #    summary => 'Directory to put completions scripts',
    #    schema  => ['array*', of => 'str*'],
    #},
);

sub _all_exec_in_PATH {
    my @res;
    for my $dir (split /:/, $ENV{PATH}) {
        opendir my($dh), $dir or next;
        for my $f (readdir $dh) {
            next if $f eq '.' || $f eq '..';
            next if $f =~ /~\z/; # skip backup files
            next unless ((-f "$dir/$f") && (-x _));
            push @res, "$dir/$f";
        }
    }
    \@res;
}

sub _set_args_defaults {
    my $args = shift;

    if (!$args->{shell}) { ($args->{shell} = $ENV{SHELL} // '') =~ s!.+/!! }
    if (!$args->{shell}) { $args->{shell} = 'bash' }
    unless ($args->{shell} ~~ @supported_shells) {
        return [412, "Unsupported shell '$args->{shell}'"];
    }

    $args->{global} //= ($> ? 0:1);

    $args->{bash_global_dir}   //= ['/usr/share/bash-completion/completions',
                                    '/etc/bash_completion.d'];
    $args->{bash_per_user_dir} //= ["$ENV{HOME}/.config/bash/completions"];
    $args->{fish_global_dir}   //= ['/usr/share/fish/completions',
                                    '/etc/fish/completions'];
    $args->{fish_per_user_dir} //= ["$ENV{HOME}/.config/fish/completions"];
    $args->{tcsh_global_dir}   //= [];
    $args->{tcsh_per_user_dir} //= ["$ENV{HOME}/.config/tcsh/completions"];
    $args->{zsh_global_dir}    //= [];
    $args->{zsh_per_user_dir}  //= ["$ENV{HOME}/.config/zsh/completions"];
}

sub _gen_completion_script {
    require String::ShellQuote;

    my %args = @_;

    my $detres = $args{detect_res};
    my $shell  = $args{shell};
    my $prog   = $detres->[3]{'func.completee'} // $args{prog};
    my $qprog  = String::ShellQuote::shell_quote($prog);
    my $comp   = $detres->[3]{'func.completer_command'};
    my $qcomp  = String::ShellQuote::shell_quote($comp);

    my $script;
    if ($shell eq 'bash') {
        if ($comp) {
            $script = "complete -C $qcomp $qprog";
        }
    }

    # fish
    # - completer_command -> check completer command if it's pericmd or
    # glcomp or glsubc

    $script = "# FRAGMENT id=shcompgen-header note=".$detres->[3]{'func.note'}.
        "\n$script\n";

    $script;
}

sub _completion_scripts_dirs {
    my %args = @_;

    my $shell  = $args{shell};
    my $global = $args{global};

    my $dirs;
    if ($shell eq 'bash') {
        $dirs = $global ? $args{bash_global_dir} :
            $args{bash_per_user_dir};
    } elsif ($shell eq 'fish') {
        $dirs = $global ? $args{fish_global_dir} :
            $args{fish_per_user_dir};
    } elsif ($shell eq 'tcsh') {
        $dirs = $global ? $args{tcsh_global_dir} :
            $args{tcsh_per_user_dir};
    } elsif ($shell eq 'zsh') {
        $dirs = $global ? $args{zsh_global_dir} :
            $args{zsh_per_user_dir};
    }
    $dirs;
}

sub _completion_script_path {
    my %args = @_;

    my $detres = $args{detect_res};
    my $prog   = $detres->[3]{'func.completee'} // $args{prog};
    my $shell  = $args{shell};
    my $global = $args{global};

    my $dir = $args{dir} // _completion_scripts_dirs(%args)->[-1];
    my $path;
    if ($shell eq 'bash') {
        $path = "$dir/$prog";
    } elsif ($shell eq 'fish') {
        $path = "$dir/$prog.fish";
    } elsif ($shell eq 'tcsh') {
        $path = "$dir/$prog";
    } elsif ($shell eq 'zsh') {
        $path = "$dir/$prog";
    }
    $path;
}

# XXX plugin based
sub _detect_prog {
    my %args = @_;

    my $prog     = $args{prog};
    my $progpath = $args{progpath};

    open my($fh), "<", $progpath or return [500, "Can't open: $!"];
    read $fh, my($buf), 2;
    my $is_script = $buf eq '#!';

    # currently we don't support non-scripts at all
    return [200, "OK", 0, {"func.reason"=>"Not a script"}] if !$is_script;

    my $is_perl_script = <$fh> =~ /perl/;
    seek $fh, 0, 0;
    my $content = do { local $/; ~~<$fh> };

    if ($content =~
            /^\s*# FRAGMENT id=shcompgen-hint command=(.+?)\s*$/m
                && $content !~ /^\s*# FRAGMENT id=shcompgen-nohint\s*$/m) {
        # program give hints in its source code that it can be completed using a
        # certain command
        return [200, "OK", 1, {
            "func.completer_command" => $1,
            "func.note" => "hint(command)",
        }];
    } elsif ($content =~
            /^\s*# FRAGMENT id=shcompgen-hint completer=1 for=(.+?)\s*$/m
                && $content !~ /^\s*# FRAGMENT id=shcompgen-nohint\s*$/m) {
        my $completee = $1;
        return [400, "completee specified in '$progpath' is not a valid ".
                    "program name: $completee"]
            unless $completee =~ $re_progname;
        return [200, "OK", 1, {
            "func.completer_command" => $prog,
            "func.completee" => $completee,
            "func.note"=>"hint(completer)",
        }];
    } elsif ($is_perl_script && $content =~
                 /^\s*(use|require)\s+(Perinci::CmdLine(?:::Any|::Lite|::Classic)?)\b/m) {
        return [200, "OK", 1, {
            "func.completer_command"=> $prog,
            "func.completer_type"=> $2,
            "func.note"=>$2,
        }];
    } elsif ($is_perl_script && $content =~
                 /^\s*(use|require)\s+(Getopt::Long::(?:Complete|Subcommand))\b/m) {
        return [200, "OK", 1, {
            "func.completer_command"=> $prog,
            "func.completer_type"=> $2,
            "func.note"=>$2,
        }];
    }
    # XXX Getopt::Long::Subcommand
    [200, "OK", 0];
}

sub _generate_or_remove {
    my $which = shift;
    my %args = @_;

    _set_args_defaults(\%args);

    my $envres = envresmulti();
  PROG:
    for my $prog0 (@{ $args{prog} }) {
        my ($prog, $progpath);
        $log->debugf("Processing program %s ...", $prog0);
        if ($prog0 =~ m!/!) {
            ($prog = $prog0) =~ s!.+/!!;
            $progpath = $prog0;
            unless (-f $progpath) {
                $log->errorf("No such file %s, skipped", $progpath);
                $envres->add_result(404, "No such file", {item_id=>$prog0});
                next PROG;
            }
        } else {
            require File::Which;
            $prog = $prog0;
            $progpath = File::Which::which($prog0);
            unless ($progpath) {
                $log->errorf("'%s' not found in PATH, skipped", $prog0);
                $envres->add_result(404, "Not in PATH", {item_id=>$prog0});
                next PROG;
            }
        }

        if ($which eq 'generate') {
            my $detres = _detect_prog(prog=>$prog, progpath=>$progpath);
            if ($detres->[0] != 200) {
                $log->errorf("Can't detect '%s': %s", $prog, $detres->[1]);
                $envres->add_result($detres->[0], $detres->[1],
                                    {item_id=>$prog0});
                next PROG;
            }
            $log->debugf("Detection result for '%s': %s", $prog, $detres);
            if (!$detres->[2]) {
                # we simply ignore undetected programs
                next PROG;
            }

            my $script = _gen_completion_script(
                %args, prog => $prog, detect_res => $detres);
            my $comppath = _completion_script_path(
                %args, prog => $prog, detect_res => $detres);

            if (-f $comppath) {
                if (!$args{replace}) {
                    $log->infof("Not replacing completion script for $prog in '$comppath' (use --replace to replace)");
                    next PROG;
                }
            }
            $log->infof("Writing completion script to %s ...", $comppath);
            eval { write_file($comppath, $script) };
            if ($@) {
                $envres->add_result(500, "Can't write to '$comppath': $@",
                                    {item_id=>$prog0});
            } else {
                $envres->add_result(200, "OK", {item_id=>$prog0});
            }
        } # generate

        if ($which eq 'remove') {
            my $comppath = _completion_script_path(%args, prog => $prog);
            unless (-f $comppath) {
                $log->debugf("Skipping %s (completion script does not exist)", $prog0);
                next PROG;
            }
            my $content;
            eval { $content = read_file($comppath) };
            if ($@) {
                $envres->add_result(500, "Can't open: $@", {item_id=>$prog0});
                next;
            };
            unless ($content =~ /^# FRAGMENT id=shcompgen-header note=(.+)\b/m) {
                $log->debugf("Skipping %s, not installed by us", $prog0);
                next;
            }
            $log->infof("Unlinking %s ...", $comppath);
            if (unlink $comppath) {
                $envres->add_result(200, "OK", {item_id=>$prog0});
            } else {
                $envres->add_result(500, "Can't unlink '$comppath': $!",
                                    {item_id=>$prog0});
            }
        } # remove

    } # for prog0

    $envres->as_struct;
}

$SPEC{init} = {
    v => 1.1,
    summary => 'Initialize shcompgen',
    description => <<'_',

This subcommand creates the completion directories and initialization shell
script, as well as run `generate`.

_
    args => {
        %common_args,
    },
};
sub init {
    my %args = @_;

    _set_args_defaults(\%args);
    my $shell = $args{shell};
    my $global = $args{global};

    my $instruction = '';

    my $dirs;
    my $init_location;
    my $init_script;
    my $init_script_path;
    if ($shell eq 'bash') {
        $init_location = $global ? "/etc/bash.bashrc" : "~/.bashrc";
        $dirs = _completion_scripts_dirs(%args);
        $init_script = <<_;
# generated by shcompgen version $App::shcompgen::VERSION
_
        $init_script .= <<'_';
_shcompgen_loader()
{
    # check if bash-completion is active by the existence of function
    # '_completion_loader'.
    local bc_active=0
    if [[ "`type -t _completion_loader`" = "function" ]]; then bc_active=1; fi

    # XXX should we use --bash-{global,per-user}-dir supplied by user here? probably.
    local dirs
    if [[ "$bc_active" = 1 ]]; then
        dirs=(~/.config/bash/completions /etc/bash_completion.d /usr/share/bash-completion/completions)
    else
        # we don't use bash-completion scripts when bash-completion is not
        # initialized because some of the completion scripts require that
        # bash-completion system is initialized first
        dirs=(~/.config/bash/completions)
    fi

    local d
    for d in ${dirs[*]}; do
        if [[ -f "$d/$1" ]]; then . "$d/$1"; return 124; fi
    done

    if [[ $bc_active = 1 ]]; then _completion_loader "$1"; return 124; fi

    # otherwise, do as default (XXX still need to fix this, we don't want to
    # install a fixed completion for unknown commands; but using 'compopt -o
    # default' also creates a 'complete' entry)
    complete -o default "$1" && return 124
}
complete -D -F _shcompgen_loader
_
        if ($global) {
            $init_script_path = "/etc/shcompgen.bashrc";
        } else {
            $init_script_path = "$ENV{HOME}/.config/shcompgen.bashrc";
        }
    } else {
        return [412, "Shell '$shell' not yet supported"];
    }

    for my $dir (@$dirs) {
        unless (-d $dir) {
            require File::Path;
            File::Path::make_path($dir)
                  or return [500, "Can't create $dir: $!"];
            $instruction .= "Directory '$dir' created.\n\n";
        }
    }

    write_file($init_script_path, $init_script);
    $instruction .= "Please put this into your $init_location:".
        "\n\n" . " . $init_script_path\n\n";

    $instruction = "Congratulations, shcompgen initialization is successful.".
        "\n\n$instruction";

    [200, "OK", $instruction];
}

$SPEC{generate} = {
    v => 1.1,
    summary => 'Generate shell completion scripts for detectable programs',
    args => {
        %common_args,
        prog => {
            summary => 'Program(s) to generate completion for',
            schema => ['array*', of=>'str*'],
            pos => 0,
            greedy => 1,
            description => <<'_',

Can contain path (e.g. `../foo`) or a plain word (`foo`) in which case will be
searched from PATH.

_
            element_completion => sub {
                require Complete::Util;

                my %args = @_;
                my $word = $args{word} // '';
                if ($word =~ m!/!) {
                    # user might want to mention a program file (e.g. ./foo)
                    return {
                        words => Complete::Util::complete_file(
                            word=>$word, ci=>1, filter=>'d|rxf'),
                        path_sep => '/',
                    };
                } else {
                    # or user might want to mention a program in PATH
                    Complete::Util::complete_program(word=>$word, ci=>1);
                }
            },
        },
        replace => {
            summary => 'Replace existing script',
            schema  => 'bool*',
            description => <<'_',

The default behavior is to skip if an existing completion script exists.

_
        },
    },
};
sub generate {
    my %args = @_;
    $args{prog} //= _all_exec_in_PATH();
    _generate_or_remove('generate', %args);
}

$SPEC{list} = {
    v => 1.1,
    summary => 'List all shell completion scripts generated by this script',
    args => {
        %common_args,
        detail => {
            schema => 'bool',
        },
    },
};
sub list {
    my %args = @_;

    _set_args_defaults(\%args);

    my @res;
    my $dirs = _completion_scripts_dirs(%args);
    for my $dir (@$dirs) {
        $log->debugf("Opening dir %s ...", $dir);
        opendir my($dh), $dir or return [500, "Can't read dir '$dir': $!"];
        for my $entry (readdir $dh) {
            next if $entry eq '.' || $entry eq '..';

            # XXX refactor: put to function (_file_to_prog)
            my $prog = $entry; $prog =~ /\.fish\z/ if $args{shell} eq 'fish';
            next unless $prog =~ $re_progname;

            # XXX refactor: put to function (_read_completion_script)
            my $comppath = _completion_script_path(
                %args, dir=>$dir, prog=>$prog);
            $log->debugf("Checking completion script '%s' ...", $comppath);
            my $content;
            eval { $content = read_file($comppath) };
            if ($@) {
                $log->warnf("Can't open file '%s': %s", $comppath, $@);
                next;
            };
            unless ($content =~ /^# FRAGMENT id=shcompgen-header note=(.+)(?:\s|$)/m) {
                $log->debugf("Skipping prog %s, not generated by us", $entry);
                next;
            }
            my $note = $1;
            if ($args{detail}) {
                push @res, {
                    prog => $prog,
                    note => $note,
                    path => $comppath,
                };
            } else {
                push @res, $prog;
            }
        }
    } # for $dir

    [200, "OK", \@res];
}

$SPEC{remove} = {
    v => 1.1,
    summary => 'Remove shell completion scripts generated by this script',
    args => {
        %common_args,
        prog => {
            summary => 'Program(s) to remove completion script of',
            schema => ['array*', of=>'str*'],
            pos => 0,
            greedy => 1,
            description => <<'_',

Can contain path (e.g. `../foo`) or a plain word (`foo`) in which case will be
searched from PATH.

_
            element_completion => sub {
                # list programs in the completion scripts dir
                require Complete::Util;

                my %args = @_;
                my $word = $args{word} // '';

                my $res = list($args{args});
                return undef unless $res->[0] == 200;
                Complete::Util::complete_array_elem(
                    array=>$res->[2], word=>$word, ci=>1);
            },
        },
    },
};
sub remove {
    my %args = @_;
    $args{prog} //= _all_exec_in_PATH();
    _generate_or_remove('remove', %args);
}

1;
# ABSTRACT:
