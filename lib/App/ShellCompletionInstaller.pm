package App::ShellCompletionInstaller;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use File::Slurp::Tiny qw();
use File::Which;
use List::Util qw(first);
use Perinci::Object;
use Perinci::Sub::Util qw(err);
use String::ShellQuote;
use Text::Fragment qw();

our %SPEC;

my $re_progname = $Text::Fragment::re_id;

$SPEC{':package'} = {
    v => 1.1,
    summary => "Manage /etc/bash-completion-prog (or ~/.bash-completion-prog)",
};

sub _f_path {
    if ($>) {
        "$ENV{HOME}/.bash-completion-prog";
    } else {
        "/etc/bash-completion-prog";
    }
}

sub _read_parse_f {
    my $path = shift // _f_path();
    my $text = (-f $path) ? File::Slurp::Tiny::read_file($path) : "";
    my $listres = Text::Fragment::list_fragments(text=>$text);
    return $listres if $listres->[0] != 200;
    [200,"OK",{path=>$path, content=>$text, parsed=>$listres->[2]}];
}

sub _write_f {
    my $path = shift // _f_path();
    my $content = shift;
    File::Slurp::Tiny::write_file($path, $content);
    [200];
}

# XXX plugin based
sub _detect_file {
    my ($prog, $path) = @_;
    open my($fh), "<", $path or return [500, "Can't open: $!"];
    read $fh, my($buf), 2;
    my $is_script = $buf eq '#!';

    # currently we don't support non-scripts at all
    return [200, "OK", 0, {"func.reason"=>"Not a script"}] if !$is_script;

    my $is_perl_script = <$fh> =~ /perl/;
    seek $fh, 0, 0;
    my $content = do { local $/; ~~<$fh> };

    my $qprog = shell_quote($prog);
    if ($content =~
            /^\s*# FRAGMENT id=bash-completion-prog-hints command=(.+?)\s*$/m
                && $content !~ /^\s*# FRAGMENT id=bash-completion-prog-nohint\s*$/m) {
        return [200, "OK", 1, {
            "func.command"=>"complete -C ".shell_quote($1)." $qprog",
            "func.note"=>"hint",
        }];
    } elsif ($content =~
            /^\s*# FRAGMENT id=bash-completion-prog-hints completer=1 for=(.+?)\s*$/m
                && $content !~ /^\s*# FRAGMENT id=bash-completion-prog-nohint\s*$/m) {
        return [200, "OK", 1, {
            "func.command"=>join(
                "; ",
                map {"complete -C $qprog ".shell_quote($_)} split(',',$1)
            ),
            "func.note"=>"hint(completer)",
        }];
    } elsif ($is_perl_script && $content =~
                 /^\s*(use|require)\s+(Perinci::CmdLine(?:::Any|::Lite)?)\b/m) {
        return [200, "OK", 1, {
            "func.command"=>"complete -C $qprog $qprog",
            "func.note"=>$2,
        }];
    } elsif ($is_perl_script && $content =~
                 /^\s*(use|require)\s+(Getopt::Long::Complete)\b/m) {
        return [200, "OK", 1, {
            "func.command"=>"complete -C $qprog $qprog",
            "func.note"=>$2,
        }];
    }
    [200, "OK", 0];
}

# add one or more programs
sub _add {
    my %args = @_;

    my $readres = _read_parse_f($args{file});
    return err("Can't read entries", $readres) if $readres->[0] != 200;

    my %existing_progs = map {$_->{id}=>1} @{ $readres->[2]{parsed} };

    my $content = $readres->[2]{content};

    my $added;
    my $envres = envresmulti();
  PROG:
    for my $prog0 (@{ $args{progs} }) {
        my $path;
        $log->infof("Processing program %s ...", $prog0);
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
        my $detectres = _detect_file($prog, $path);
        if ($detectres->[0] != 200) {
            $log->errorf("Can't detect '%s': %s", $prog, $detectres->[1]);
            $envres->add_result($detectres->[0], $detectres->[1],
                                {item_id=>$prog0});
            next PROG;
        }
        $log->debugf("Detection result for '%s': %s", $prog, $detectres);
        if (!$detectres->[2]) {
            # we simply ignore undetected programs
            next PROG;
        }

        if ($args{replace}) {
            if ($existing_progs{$prog}) {
                $log->infof("Replacing entry in %s: %s",
                            $readres->[2]{path}, $prog);
            } else {
                $log->infof("Adding entry to %s: %s",
                            $readres->[2]{path}, $prog);
            }
        } else {
            if ($existing_progs{$prog}) {
                $log->debugf("Entry already exists in %s: %s, skipped",
                             $readres->[2]{path}, $prog);
                next PROG;
            } else {
                $log->infof("Adding entry to %s: %s",
                            $readres->[2]{path}, $prog);
            }
        }

        my $insres = Text::Fragment::insert_fragment(
            text=>$content, id=>$prog,
            payload=>$detectres->[3]{'func.command'},
            ((attrs=>{note=>$detectres->[3]{'func.note'}}) x !!$detectres->[3]{'func.note'}));
        $envres->add_result($insres->[0], $insres->[1],
                            {item_id=>$prog0});
        next if $insres->[0] == 304;
        next unless $insres->[0] == 200;
        $added++;
        $content = $insres->[2]{text};
    }

    if ($added) {
        my $writeres = _write_f($args{file}, $content);
        return err("Can't write", $writeres) if $writeres->[0] != 200;
    }

    $envres->as_struct;
}

sub _remove {
    my %args = @_;
    my $readres = _read_parse_f($args{file});
    return err("Can't read entries", $readres) if $readres->[0] != 200;

    my $envres = envresmulti();

    my $content = $readres->[2]{content};
    my $deleted;
    for my $entry (@{ $readres->[2]{parsed} }) {
        $log->debugf("Processing entry: %s", $entry);
        my $remove;
        if ($args{criteria}) {
            $remove = $args{criteria}->($entry);
        } elsif ($args{progs}) {
            use experimental 'smartmatch';
            $remove = 1 if $entry->{id} ~~ @{ $args{progs} };
        } else {
            die "BUG: no criteria nor progs are given";
        }

        next unless $remove;
        $log->infof("Removing from %s: %s",
                    $readres->[2]{path}, $entry->{id});
        my $delres = Text::Fragment::delete_fragment(
            text=>$content, id=>$entry->{id});
        next if $delres->[0] == 304;
        $envres->add_result($delres->[0], $delres->[1],
                            {item_id=>$entry->{id}});
        next if $delres->[0] != 200;
        $deleted++;
        $content = $delres->[2]{text};
    }

    if ($deleted) {
        my $writeres = _write_f($args{file}, $content);
        return err("Can't write", $writeres) if $writeres->[0] != 200;
    }

    $envres->as_struct;
}

sub _list {
    my %args = @_;

    my $res = _read_parse_f($args{file} // _f_path());
    return $res if $res->[0] != 200;

    my @res;
    for (@{ $res->[2]{parsed} }) {
        if ($args{detail}) {
            push @res, {id=>$_->{id}, payload=>$_->{payload}, note=>$_->{attrs}{note}};
        } else {
            push @res, $_->{id};
        }
    }

    [200, "OK", \@res];
}

sub _clean {
    require File::Which;

    my %args = @_;
    _remove(
        criteria => sub {
            my $entry = shift;
            if (File::Which::which($entry->{id})) {
                return 0;
            }
            1;
        },
        %args,
    );
}

1;
# ABSTRACT: Backend for bash-completion-prog script
