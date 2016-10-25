package App::shcompgen;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any::IfLOG '$log';

use File::Slurper qw(read_text write_text);
use Perinci::Object;
use Perinci::Sub::Util qw(err);

our %SPEC;

my $re_progname = qr/\A[A-Za-z0-9_.,:-]+\z/;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Generate shell completion scripts',
};

my $_complete_prog = sub {
    require Complete::File;
    require Complete::Program;

    my %args = @_;
    my $word = $args{word} // '';
    if ($word =~ m!/!) {
        # user might want to mention a program file (e.g. ./foo)
        return {
            words => Complete::File::complete_file(
                word=>$word, ci=>1, filter=>'d|rxf'),
            path_sep => '/',
        };
    } else {
        # or user might want to mention a program in PATH
        Complete::Program::complete_program(word=>$word, ci=>1);
    }
};

our @supported_shells = qw(bash fish zsh tcsh);
our %shell_arg = (
    shell => {
        summary => 'Override guessing and select shell manually',
        schema => ['str*', {in=>\@supported_shells}],
        tags => ['common'],
    },
);
our %common_args = (
    %shell_arg,
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
        tags => ['common'],
    },

    bash_global_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        default => ['/usr/share/bash-completion/completions',
                    '/etc/bash_completion.d'],
        tags => ['common'],
    },
    bash_per_user_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        tags => ['common'],
    },

    fish_global_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        default => ['/usr/share/fish/completions', '/etc/fish/completions'],
        tags => ['common'],
    },
    fish_per_user_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        tags => ['common'],
    },

    tcsh_global_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        default => ['/etc/tcsh/completions'],
        tags => ['common'],
    },
    tcsh_per_user_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        tags => ['common'],
    },

    zsh_global_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        default => ['/usr/local/share/zsh/site-functions'],
        tags => ['common'],
    },
    zsh_per_user_dir => {
        summary => 'Directory to put completions scripts',
        schema  => ['array*', of => 'str*'],
        tags => ['common'],
    },
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

    if (!$args->{shell}) {
        require Shell::Guess;
        my $sh = Shell::Guess->running_shell;
        my $n = $sh->{name};
        $n = "zsh" if $n eq 'z';
        $n = "tcsh" if $n eq 'c';
        $n = "bash" if $n eq 'bourne'; # under make
        $args->{shell} = $n;
    }
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
    $args->{tcsh_global_dir}   //= ['/etc/tcsh/completions'];
    $args->{tcsh_per_user_dir} //= ["$ENV{HOME}/.config/tcsh/completions"];
    $args->{zsh_global_dir}    //= ['/usr/local/share/zsh/site-functions'];
    $args->{zsh_per_user_dir}  //= ["$ENV{HOME}/.config/zsh/completions"];
    [200];
}

sub _tcsh_init_script_path {
    my %args = @_;
    if ($args{global}) {
        return "/etc/shcompgen.tcshrc";
    } else {
        return "$ENV{HOME}/.config/shcompgen.tcshrc";
    }
}

sub _gen_tcsh_init_script {
    my %args = @_;
    my $dirs = $args{global} ?
        $args{tcsh_global_dir} : $args{tcsh_per_user_dir};
    my @defs;
    for my $dir (@$dirs) {
        next unless -d $dir;
        for my $file (<$dir/*>) {
            open my $fh, "<", $file or do {
                warn "Can't open '$file': $!, skipped\n";
                next;
            };
            my $line = <$fh>;
            $line .= "\n" unless $line =~ /\n\z/;
            push @defs, $line;
        }
    }
    join(
        "",
        "# Generated by shcompgen on ", scalar(localtime), "\n",
        @defs,
    );
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
    my $args   = $detres->[3]{'func.completer_command_args'};
    my $qargs  = String::ShellQuote::shell_quote($args) if defined $args;

    my $header_at_bottom;
    my $script;
    if ($shell eq 'bash') {
        if (defined $args) {

            $script = q|
_|.$prog.q| ()
{
    local words
    words=("${COMP_WORDS[@]:0:1}")
    # insert arguments into the second element
    words+=(|.$qargs.q|)
    words+=("${COMP_WORDS[@]:1:COMP_CWORD}")
    local s1="${words[@]}"
    local point=${#s1}
    words+=("${COMP_WORDS[@]:COMP_CWORD+1}")

    #echo "D:words = ${words[@]}"
    #echo "D:point = $point"

    #echo "D:cmd = COMP_LINE=\"${words[@]}\" COMP_POINT=$point |.$comp.q|"

    COMPREPLY=( `COMP_LINE="${words[@]}" COMP_POINT=$point |.$comp.q|` )

    #echo "D:reply = ${COMPREPLY[@]}"
}
complete -F _|."$prog $qprog".q|
|;
        } else {
            $script = "complete -C $qcomp $qprog";
        }

    } elsif ($shell eq 'zsh') {

        if (defined $args) {
            die "TODO: args not yet supported";
        } else {
            $header_at_bottom++;
            $script = q|#compdef |.$prog.q|
_|.$prog.q|() {
    si=$IFS
    compadd -- $(COMP_LINE=$BUFFER COMP_POINT=$CURSOR |.$qcomp.q|)
    IFS=$si
}
_|.$prog.q| "$@"
|;
        }

    } elsif ($shell eq 'tcsh') {

        if (defined $args) {
            $header_at_bottom++;
            $script = "complete $qprog 'p/*/`$qcomp $args`/'\n";
        } else {
            $header_at_bottom++;
            $script = "complete $qprog 'p/*/`$qcomp`/'\n";
        }

    } elsif ($shell eq 'fish') {

        require File::Which;
        my $path = File::Which::which($comp);
        my $type = $detres->[3]{'func.completer_type'};
        if ($type eq 'Getopt::Long' || $type eq 'Getopt::Long::Complete') {
            require Complete::Fish::Gen::FromGetoptLong;
            my $gen_res = Complete::Fish::Gen::FromGetoptLong::gen_fish_complete_from_getopt_long_script(
                filename => $path,
                cmdname => $prog,
                compname => $comp,
            );
            if ($gen_res->[0] != 200) {
                $log->errorf("Can't generate fish completion script for '%s': %s", $path, $gen_res);
                $script = "# Can't generate fish completion script for '$path': $gen_res->[0] - $gen_res->[1]\n";
                goto L1;
            }
            $script = $gen_res->[2];
        } elsif ($type eq 'Perinci::CmdLine') {
            require Complete::Fish::Gen::FromPerinciCmdLine;
            my $gen_res = Complete::Fish::Gen::FromPerinciCmdLine::gen_fish_complete_from_perinci_cmdline_script(
                filename => $path,
                cmdname => $prog,
                compname => $comp,
            );
            if ($gen_res->[0] != 200) {
                $log->errorf("Can't generate fish completion script for '%s': %s", $path, $gen_res);
                $script = "# Can't generate fish completion script for '$path': $gen_res->[0] - $gen_res->[1]\n";
                goto L1;
            }
            $script = $gen_res->[2];
        } else {
            $script = "# TODO for type=$type\n";
        }
    } else {
        die "Sorry, shells other than bash/fish are not supported yet";
    }

  L1:
    if ($header_at_bottom) {
        $script = "$script\n".
            "# FRAGMENT id=shcompgen-header note=".
                ($detres->[3]{'func.note'} // ''). "\n";
    } else {
        $script = "# FRAGMENT id=shcompgen-header note=".
            ($detres->[3]{'func.note'} // ''). "\n$script\n";
    }

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
        $path = "$dir/_$prog";
    }
    $path;
}

# detect whether we can generate completion script for a program, under a given
# shell
sub _detect_prog {
    my %args = @_;

    my $shell    = $args{shell};
    my $prog     = $args{prog};
    my $progpath = $args{progpath};

    open my($fh), "<", $progpath or return [500, "Can't open '$progpath': $!"];
    read $fh, my($buf), 2;
    my $is_script = $buf eq '#!';

    # currently we don't support non-scripts at all
    return [200, "OK", 0, {"func.reason"=>"Not a script"}] if !$is_script;

    my $is_perl_script = <$fh> =~ /perl/;
    seek $fh, 0, 0;
    my $content = do { local $/; ~~<$fh> };

    my %extrametas;

  DETECT:
    {
        if ($content =~
                /^\s*# FRAGMENT id=shcompgen-hint command=(.+?)(?:\s+command_args=(.+))?\s*$/m
                && $content !~ /^\s*# FRAGMENT id=shcompgen-nohint\s*$/m) {
            # program give hints in its source code that it can be completed using a
            # certain command
            my $cmd = $1;
            my $args = $2;
            if (defined($args) && $args =~ s/\A"//) {
                $args =~ s/"\z//;
                $args =~ s/\\(.)/$1/g;
            }
            if ($shell eq 'fish') {
                # for fish, we need to make sure first that we can extract
                # cmdline-options from the completer program
                require File::Which;
                my $cmdpath = File::Which::which($cmd);
                my $cmddet_res = _detect_prog(
                    prog => $cmd,
                    progpath => $cmdpath,
                    shell => $shell,
                );
                my $reason;
                {
                    if ($cmddet_res->[0] != 200) {
                        $reason = "$cmddet_res->[0] - $cmddet_res->[1]";
                        last;
                    }
                    if (!$cmddet_res->[2]) {
                        $reason = "'$cmd' is not supported by shcompgen";
                    }
                    if ($cmddet_res->[3]{'completer_command'} &&
                            $cmddet_res->[3]{'completer_command'} ne $cmd) {
                        $reason = "multiple indirection of completer is currently not supported";
                        last;
                    }
                    if ($cmddet_res->[3]{'func.completer_type'} && $cmddet_res->[3]{'func.completer_type'} !~
                            /^(Getopt::Long(::Complete)?|Perinci::CmdLine(?:::\w+)?)$/) {
                        $reason = "currently only Getopt::Long-/Getopt::Long::Complete-/Perinci::CmdLine-based scripts are supported";
                        last;
                    }
                    $extrametas{'func.completer_type'} =
                        $cmddet_res->[3]{'func.completer_type'};
                }
                return [200, "Program '$prog' is completed by ".
                            "'$cmd' (hint(command)), but we don't support ".
                            "creating completion script with '$cmd'".
                            ": $reason", 0]
                    if $reason;
            }
            return [200, "OK", 1, {
                "func.completer_command" => $cmd,
                "func.completer_command_args" => $args,
                "func.note" => "hint(command)",
                %extrametas,
            }];
        }
        if(!$args{_skip_completer_hint} &&
               $content =~
               /^\s*# FRAGMENT id=shcompgen-hint completer=1 for=(.+?)\s*$/m
               && $content !~ /^\s*# FRAGMENT id=shcompgen-nohint\s*$/m) {
            my $completee = $1;
            return [400, "completee specified in '$progpath' is not a valid ".
                        "program name: $completee"]
                unless $completee =~ $re_progname;
            if ($shell eq 'fish') {
                # for fish, we need to make sure first that we can extract
                # cmdline-options from the completer program
                require File::Which;
                my $det_res2 = _detect_prog(
                    prog => $prog,
                    progpath => $progpath,
                    shell => $shell,
                    _skip_completer_hint=>1,
                );
                my $reason;
                {
                    if ($det_res2->[0] != 200) {
                        $reason = "$det_res2->[0] - $det_res2->[1]";
                        last;
                    }
                    if (!$det_res2->[2]) {
                        $reason = "'$prog' is not supported by shcompgen";
                    }
                    if ($det_res2->[3]{'completer_command'} &&
                            $det_res2->[3]{'completer_command'} ne $prog) {
                        $reason = "multiple indirection of completer is currently not supported";
                        last;
                    }
                    if ($det_res2->[3]{'func.completer_type'} && $det_res2->[3]{'func.completer_type'} !~
                            /^(Getopt::Long(::Complete|::Subcommand)?|Perinci::CmdLine(?:::\w+)?)$/) {
                        $reason = "currently only Getopt::Long-/Getopt::Long::Complete-/Perinci::CmdLine-based scripts are supported";
                        last;
                    }
                    $extrametas{'func.completer_type'} = $det_res2->[3]{'func.completer_type'};
                }
                return [200, "Program '$prog' is a completer for ".
                            "'$completee' (hint(completer)), but we don't support ".
                            "creating completion script with '$prog'".
                            ": $reason", 0]
                    if $reason;
            }
            return [200, "OK", 1, {
                "func.completer_command" => $prog,
                "func.completee" => $completee,
                "func.note"=>"hint(completer)",
                %extrametas,
            }];
        }

        if ($is_perl_script &&
                # regex split here because i found a pathological case of very
                # long matching time againt 'rsybak' datapacked script (~ 4M)
                $content =~ /^\s*((?:use|require)\s+(Getopt::Long::Complete))\b/m ||
                $shell ne 'fish' &&
                $content =~ /^\s*((?:use|require)\s+(Getopt::Long::Subcommand))\b/m) {
            return [200, "OK", 1, {
                "func.completer_command"=> $prog,
                "func.completer_type"=> $2,
                "func.note"=>"perl use/require statement: $1",
            }];
        }

        if ($shell eq 'fish' && $is_perl_script &&
                $content =~ /^\s*((?:use|require)\s+(Getopt::Long))\b/m) {
            return [200, "OK", 1, {
                "func.completer_command" => $prog,
                "func.completer_type" => $2,
                "func.note"=>"perl use/require statement: $1",
            }];
        }

      DETECT_PERICMD:
        {
            last unless $is_perl_script;
            require Perinci::CmdLine::Util;
            my $det_res = Perinci::CmdLine::Util::detect_perinci_cmdline_script(
                string => $content);
            $log->tracef("Perinci::CmdLine detection result: %s", $det_res);
            last unless $det_res->[2];

            # pericmd-inline doesn't currently support self-completion
            last if $det_res->[3]{'func.is_inline'};

            return [200, "OK", 1, {
                "func.completer_command"=> $prog,
                "func.completer_type"=> "Perinci::CmdLine",
                "func.note"=>"detected using Perinci::CmdLine::Util",
                "func.pericmd_detect_result" => $det_res,
            }];
        }
    }
    [200, "OK", 0];
}

sub _generate_or_remove {
    my $which0 = shift;
    my %args = @_;

    my $setdef_res = _set_args_defaults(\%args);
    return $setdef_res unless $setdef_res->[0] == 200;

    # to avoid writing a file and then removing the file again in the same run
    my %written_files;

    my %removed_files;

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

        my $which = $which0;
        if ($which eq 'generate') {
            my $detres = _detect_prog(prog=>$prog, progpath=>$progpath, shell=>$args{shell});
            if ($detres->[0] != 200) {
                $log->errorf("Can't detect '%s': %s", $prog, $detres->[1]);
                $envres->add_result($detres->[0], $detres->[1],
                                    {item_id=>$prog0});
                next PROG;
            }
            $log->debugf("Detection result for '%s': %s", $prog, $detres);
            if (!$detres->[2]) {
                if ($args{remove}) {
                    $which = 'remove';
                    goto REMOVE;
                } else {
                    next PROG;
                }
            }

            my $script = _gen_completion_script(
                %args, prog => $prog, detect_res => $detres);
            my $comppath = _completion_script_path(
                %args, prog => $prog, detect_res => $detres);

            if ($args{stdout}) {
                print $script;
                next PROG;
            }

            if (-f $comppath) {
                if (!$args{replace}) {
                    $log->infof("Not replacing completion script for $prog in '$comppath' (use --replace to replace)");
                    $envres->add_result(304, "Not replaced (already exists)", {item_id=>$prog0});
                    next PROG;
                }
            }
            $log->infof("Writing completion script to %s ...", $comppath);
            $written_files{$comppath}++;
            eval { write_text($comppath, $script) };
            if ($@) {
                $envres->add_result(500, "Can't write to '$comppath': $@",
                                    {item_id=>$prog0});
            } else {
                $envres->add_result(200, "OK", {item_id=>$prog0});
            }
        } # generate

      REMOVE:
        if ($which eq 'remove') {
            my $comppath = _completion_script_path(%args, prog => $prog);
            unless (-f $comppath) {
                $log->debugf("Skipping %s (completion script does not exist)", $prog0);
                $envres->add_result(304, "Completion does not exist", {item_id=>$prog0});
                next PROG;
            }
            my $content;
            eval { $content = read_text($comppath) };
            if ($@) {
                $envres->add_result(500, "Can't open '$comppath': $@", {item_id=>$prog0});
                next;
            };
            unless ($content =~ /^# FRAGMENT id=shcompgen-header note=(.+)\b/m) {
                $log->debugf("Skipping %s, not installed by us", $prog0);
                $envres->add_result(304, "Not installed by us", {item_id=>$prog0});
                next PROG;
            }
            if ($written_files{$comppath}) {
                # not removing files we already wrote
                next PROG;
            }
            $log->infof("Unlinking %s ...", $comppath);
            if (unlink $comppath) {
                $envres->add_result(200, "OK", {item_id=>$prog0});
                $removed_files{$comppath}++;
            } else {
                $envres->add_result(500, "Can't unlink '$comppath': $!",
                                    {item_id=>$prog0});
            }
        } # remove

    } # for prog0

    if (keys(%written_files) || keys(%removed_files)) {
        if ($args{shell} eq 'tcsh') {
            my $init_script_path = _tcsh_init_script_path(%args);
            my $init_script = _gen_tcsh_init_script(%args);
            $log->debugf("Re-writing init script %s ...", $init_script_path);
            write_text($init_script_path, $init_script);
        }
    }

    $envres->as_struct;
}

$SPEC{guess_shell} = {
    v => 1.1,
    summary => 'Guess running shell',
    args => {
    },
};
sub guess_shell {
    my %args = @_;

    my $setdef_res = _set_args_defaults(\%args);
    return $setdef_res unless $setdef_res->[0] == 200;

    [200, "OK", $args{shell}];
}

$SPEC{detect_prog} = {
    v => 1.1,
    summary => "Detect a program",
    args => {
        %shell_arg,
        prog => {
            schema => 'str*',
            completion => $_complete_prog,
            req => 1,
            pos => 0,
        },
    },
    'cmdline.default_format' => 'json',
};
sub detect_prog {
    require File::Which;

    my %args = @_;

    _set_args_defaults(\%args);

    my $progname = $args{prog};
    my $progpath = File::Which::which($progname);

    return [404, "No such program '$progname'"] unless $progpath;
    $progname =~ s!.+/!!;

    _detect_prog(
        prog => $progname,
        progpath => $progpath,
        shell => $args{shell},
    );
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

    my $setdef_res = _set_args_defaults(\%args);
    return $setdef_res unless $setdef_res->[0] == 200;

    my $shell = $args{shell};
    my $global = $args{global};

    my $instruction = '';

    my $dirs;
    my $init_location;
    my $init_script;
    my $init_script_path;

    $dirs = _completion_scripts_dirs(%args);

    if ($shell eq 'bash') {
        $init_location = $global ? "/etc/bash.bashrc" : "~/.bashrc";
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
        $instruction .= "Please put this into your $init_location:".
            "\n\n" . " . $init_script_path\n\n";
    } elsif ($shell eq 'zsh') {
        $init_location = $global ? "/etc/zsh/zshrc" : "~/.zshrc";
        $init_script = <<_;
# generated by shcompgen version $App::shcompgen::VERSION
_
        $init_script .= <<'_';
local added_dir
for d in ~/.config/zsh/completions; do
  if [[ ${fpath[(i)$d]} == "" || ${fpath[(i)$d]} -gt ${#fpath} ]]; then
    fpath=($d $fpath)
    added_dir=1
  fi
done
if [[ $added_dir == 1 ]]; then compinit; fi
_

        if ($global) {
            $init_script_path = "/etc/shcompgen.zshrc";
        } else {
            $init_script_path = "$ENV{HOME}/.config/shcompgen.zshrc";
        }
        $instruction .= "Please put this into your $init_location:".
            "\n\n" . " . $init_script_path\n\n";
    } elsif ($shell eq 'fish') {
        # nothing to do, ready by default
    } elsif ($shell eq 'tcsh') {
        $init_location = $global ? "/etc/csh.cshrc" : "~/.tcshrc";
        $init_script = _gen_tcsh_init_script(%args);
        $init_script_path = _tcsh_init_script_path(%args);
        $instruction .= "Please put this into your $init_location:".
            "\n\n" . " source $init_script_path\n\n";
    } else {
        return [412, "Shell '$shell' not yet supported"];
    }

    for my $dir (@$dirs) {
        unless (-d $dir) {
            require File::Path;
            $log->tracef("Creating directory %s ...", $dir);
            File::Path::make_path($dir)
                  or return [500, "Can't create $dir: $!"];
            $instruction .= "Directory '$dir' created.\n\n";
        }
    }

    if ($init_script) {
        write_text($init_script_path, $init_script);
    }

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
            element_completion => $_complete_prog,
        },
        replace => {
            summary => 'Replace existing script',
            schema  => ['bool*', is=>1],
            description => <<'_',

The default behavior is to skip if an existing completion script exists.

_
        },
        remove => {
            summary => 'Remove completion for script that (now) is '.
                'not detected to have completion',
            schema  => ['bool*', is=>1],
            description => <<'_',

The default behavior is to simply ignore existing completion script if the
program is not detected to have completion. When the `remove` setting is
enabled, however, such existing completion script will be removed.

_
        },
        stdout => {
            summary => 'Output completion script to STDOUT',
            schema => ['bool', is=>1],
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
            cmdline_aliases => {l=>{}},
        },
    },
};
sub list {
    my %args = @_;

    my $setdef_res = _set_args_defaults(\%args);
    return $setdef_res unless $setdef_res->[0] == 200;

    my @res;
    my $resmeta = {};
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
            eval { $content = read_text($comppath) };
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

    $resmeta->{'table.fields'} = [qw/prog path note/] if $args{detail};

    [200, "OK", \@res, $resmeta];
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
