package App::ShellCompletionInstaller;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use File::Slurp::Tiny qw(read_file write_file);
use File::Which;
use List::Util qw(first);
use Perinci::Object;
use Perinci::Sub::Util qw(err);
use String::ShellQuote;

our %SPEC;

my $re_progname = qr/\A[A-Za-z0-9_.,:-]+\z/;

$SPEC{':package'} = {
    v => 1.1,
};

sub _gen_completion_script {
    my %args = @_;

    my $detres = $args{detect_res};
    my $shell  = $args{shell};
    my $prog   = $args{prog};
    my $qprog  = shell_quote($prog);
    my $comp   = $detres->[3]{'func.completer_command'};
    my $qcomp  = shell_quote($comp);

    my $script;
    if ($shell eq 'bash') {
        if ($comp) {
            $script = "complete -C $qcomp $qprog";
        }
    }

    # fish
    # - completer_command -> check completer command if it's pericmd or
    # glcomp or glsubc

    $script = "# FRAGMENT id=shcompinst-header note=".$detres->[3]{'func.note'}.
        "\n$script\n";

    $script;
}

sub _completion_scripts_dir {
    my %args = @_;

    my $shell  = $args{shell};
    my $global = $args{global};

    my $dir;
    if ($shell eq 'bash') {
        $dir = $global ? $args{bash_global_dir} :
            $args{bash_per_user_dir};
    } elsif ($shell eq 'fish') {
        $dir = $global ? $args{fish_global_dir} :
            $args{fish_per_user_dir};
    } elsif ($shell eq 'tcsh') {
        $dir = $global ? $args{tcsh_global_dir} :
            $args{tcsh_per_user_dir};
    } elsif ($shell eq 'zsh') {
        $dir = $global ? $args{zsh_global_dir} :
            $args{zsh_per_user_dir};
    }
    $dir;
}

sub _completion_script_path {
    my %args = @_;

    my $detres = $args{detect_res};
    my $prog   = $detres->[3]{'func.completee'} // $args{prog};
    my $shell  = $args{shell};
    my $global = $args{global};

    my $dir = $args{dir} // _completion_scripts_dir(%args);
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

    my $prog = $args{prog};
    my $path = $args{path};

    open my($fh), "<", $path or return [500, "Can't open: $!"];
    read $fh, my($buf), 2;
    my $is_script = $buf eq '#!';

    # currently we don't support non-scripts at all
    return [200, "OK", 0, {"func.reason"=>"Not a script"}] if !$is_script;

    my $is_perl_script = <$fh> =~ /perl/;
    seek $fh, 0, 0;
    my $content = do { local $/; ~~<$fh> };

    if ($content =~
            /^\s*# FRAGMENT id=shcompinst-hint command=(.+?)\s*$/m
                && $content !~ /^\s*# FRAGMENT id=shcompinst-nohint\s*$/m) {
        # program give hints in its source code that it can be completed using a
        # certain command
        return [200, "OK", 1, {
            "func.completer_command" => $1,
            "func.note" => "hint(command)",
        }];
    } elsif ($content =~
            /^\s*# FRAGMENT id=shcompinst-hint completer=1 for=(.+?)\s*$/m
                && $content !~ /^\s*# FRAGMENT id=shcompinst-nohint\s*$/m) {
        my $completee = $1;
        return [400, "completee specified in '$path' is not a valid ".
                    "program name: $completee"]
            unless $completee =~ $re_progname;
        return [200, "OK", 1, {
            "func.completer_command" => $prog,
            "func.completee" => $completee,
            "func.note"=>"hint(completer)",
        }];
    } elsif ($is_perl_script && $content =~
                 /^\s*(use|require)\s+(Perinci::CmdLine(?:::Any|::Lite)?)\b/m) {
        return [200, "OK", 1, {
            "func.completer_command"=> $prog,
            "func.completer_type"=> $2,
            "func.note"=>$2,
        }];
    } elsif ($is_perl_script && $content =~
                 /^\s*(use|require)\s+(Getopt::Long::Complete)\b/m) {
        return [200, "OK", 1, {
            "func.completer_command"=> $prog,
            "func.completer_type"=> $2,
            "func.note"=>$2,
        }];
    }
    # XXX Getopt::Long::Subcommand
    [200, "OK", 0];
}

# install completion script for one or more programs
sub _install {
    my %args = @_;

    my $envres = envresmulti();
  PROG:
    for my $prog0 (@{ $args{progs} }) {
        my $path;
        $log->debugf("Processing program %s ...", $prog0);
        if ($prog0 =~ m!/!) {
            $path = $prog0;
            unless (-f $path) {
                $log->errorf("No such file '$path', skipped");
                $envres->add_result(404, "No such file", {item_id=>$prog0});
                next PROG;
            }
        } else {
            $path = which($prog0);
            unless ($path) {
                $log->errorf("'%s' not found in PATH, skipped", $prog0);
                $envres->add_result(404, "Not in PATH", {item_id=>$prog0});
                next PROG;
            }
        }
        my $prog = $prog0; $prog =~ s!.+/!!;
        my $detres = _detect_prog(prog=>$prog, path=>$path);
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
            prog => $prog, detect_res => $detres, %args);
        my $comppath = _completion_script_path(
            prog => $prog, detect_res => $detres, %args);

        if (-f $comppath) {
            if (!$args{replace}) {
                $log->warnf("Not replacing completion script for $prog in '$comppath' (use --replace to replace)");
                next PROG;
            }
        }
        eval { write_file($comppath, $script) };
        if ($@) {
            $envres->add_result(500, "Can't write to '$comppath': $@",
                                {item_id=>$prog0});
        } else {
            $envres->add_result(200, "OK", {item_id=>$prog0});
        }
    } # for prog0

    $envres->as_struct;
}

sub _list {
    my %args = @_;

    my @res;
    my $dir = _completion_scripts_dir(%args);
    $log->tracef("Opening dir %s ...", $dir);
    opendir my($dh), $dir or return [500, "Can't read dir '$dir': $!"];
    for my $entry (readdir $dh) {
        next if $entry eq '.' || $entry eq '..';
        # XXX leaky abstraction
        my $prog = $entry; $prog =~ /\.fish\z/ if $args{shell} eq 'fish';
        next unless $prog =~ $re_progname;
        my $comppath = _completion_script_path(%args, dir=>$dir, prog=>$prog);
        $log->tracef("Checking completion script '%s' ...", $comppath);
        my $content;
        eval { $content = read_file($comppath) };
        if ($@) {
            $log->warnf("Can't open file '%s': %s", $comppath, $@);
            next;
        };
        unless ($content =~ /^# FRAGMENT id=shcompinst-header note=(.+)\b/m) {
            $log->debugf("Skipping prog %s, not installed by us", $entry);
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

    [200, "OK", \@res, {('cmdline.default_format'=>'text-simple') x !$args{detail}}];
}

sub _uninstall {
    my %args = @_;

    my $envres = envresmulti();

    # XXX refactor: merge with _install to remove code duplication

  PROG:
    for my $prog0 (@{ $args{progs} }) {
        my $path;
        $log->debugf("Processing program %s ...", $prog0);
        if ($prog0 =~ m!/!) {
            $path = $prog0;
            unless (-f $path) {
                $log->errorf("No such file '$path', skipped");
                $envres->add_result(404, "No such file", {item_id=>$prog0});
                next PROG;
            }
        } else {
            $path = which($prog0);
            unless ($path) {
                $log->errorf("'%s' not found in PATH, skipped", $prog0);
                $envres->add_result(404, "Not in PATH", {item_id=>$prog0});
                next PROG;
            }
        }
        my $prog = $prog0; $prog =~ s!.+/!!;
        my $comppath = _completion_script_path(
            prog => $prog, %args);

        unless (-f $comppath) {
            $log->infof("Skipping %s (completion script does not exist)", $prog0);
            next PROG;
        }
        my $content;
        eval { $content = read_file($comppath) };
        if ($@) {
            $envres->add_result(500, "Can't open: $@", {item_id=>$prog0});
            next;
        };
        unless ($content =~ /^# FRAGMENT id=shcompinst-header note=(.+)\b/m) {
            $log->debugf("Skipping %s, not installed by us", $prog0);
            next;
        }
        if ($args{criteria} && !$args{criteria}->($prog)) {
            $log->debugf("Skipping %s", $prog0);
            next;
        }

        if (unlink $comppath) {
            $envres->add_result(200, "OK", {item_id=>$prog0});
        } else {
            $envres->add_result(500, "Can't unlink '$comppath': $!",
                                {item_id=>$prog0});
        }
    } # for prog0

    $envres->as_struct;
}

sub _clean {
    require File::Which;

    my %args = @_;
    _uninstall(
        criteria => sub {
            my $prog = shift;
            if (File::Which::which($prog)) {
                return 0;
            }
            1;
        },
        %args,
    );
}

1;
# ABSTRACT: Backend for shell-completion-installer script
