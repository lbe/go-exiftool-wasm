package File::CheckTree;

use 5.006;
use Cwd;
use Exporter;
use File::Spec;
use warnings;
use strict;

our $VERSION = '4.41';
our @ISA     = qw(Exporter);
our @EXPORT  = qw(validate);


my $Warnings;

sub validate {
    my ( $starting_dir, $file, $test, $cwd, $oldwarnings );

    $starting_dir = cwd;

    $cwd      = "";
    $Warnings = 0;

    foreach my $check ( split /\n/, $_[0] ) {
        my ( $testlist, @testlist );

        next if $check =~ /^\s*#/ || $check =~ /^\s*$/;

        if (   $check =~ m/^\s*"([^"]+)"\s+(.*?)\s*$/
            or $check =~ m/^\s*'([^']+)'\s+(.*?)\s*$/
            or $check =~ m/^\s*(\S+?)\s+(\S.*?)\s*$/ )
        {
            ( $file, $test ) = ( $1, $2 );
        }
        else {
            die "Malformed line: '$check'";
        }

        if ( $test =~ s/ ^ (!?-) (\w{2,}) \b /$1Z/x ) {
            $testlist = $2;
            @testlist = split( //, $testlist );
        }
        else {
            @testlist = ('Z');
        }

        $oldwarnings = $Warnings;

        foreach my $one (@testlist) {
            my $this = $test;

            $file = File::Spec->catfile( $cwd, $file )
              if $cwd && !File::Spec->file_name_is_absolute($file);

            $this =~ s/(-\w\b)/$1 "\$file"/g;

            $this =~ s/-Z/-$one/;

            if ( $this =~ /^cd\b/ ) {
                $this .= ' || die "cannot cd to $file\n"';
                $this =~ s/\bcd\b/chdir(\$cwd = '$file')/;
            }
            else {
                $this .= ' || warn' unless $this =~ /\|\|/;

                $this =~ s/ ^ ( (\S+) \s+ \S+ ) \s* \|\| \s* (die|warn) \s* $
                          /$1 || valmess('$3', '$2', \$file)/x;
            }

            {
                my $orig_sigwarn = $SIG{__WARN__};
                local $SIG{__WARN__} = sub {
                    ++$Warnings;
                    if ($orig_sigwarn) {
                        $orig_sigwarn->(@_);
                    }
                    else {
                        warn "@_";
                    }
                };

                eval $this;

                if ( my $err = $@ ) {
                    if ( $starting_dir ne cwd ) {
                        chdir($starting_dir) || die "$starting_dir: $!";
                    }
                    die $err;
                }
            }

            last if $Warnings > $oldwarnings;
        }
    }

    if ( $starting_dir ne cwd ) {
        chdir($starting_dir) || die "chdir $starting_dir: $!";
    }

    return $Warnings;
}

my %Val_Message = (
    'r' => "is not readable by uid $>.",
    'w' => "is not writable by uid $>.",
    'x' => "is not executable by uid $>.",
    'o' => "is not owned by uid $>.",
    'R' => "is not readable by you.",
    'W' => "is not writable by you.",
    'X' => "is not executable by you.",
    'O' => "is not owned by you.",
    'e' => "does not exist.",
    'z' => "does not have zero size.",
    's' => "does not have non-zero size.",
    'f' => "is not a plain file.",
    'd' => "is not a directory.",
    'l' => "is not a symbolic link.",
    'p' => "is not a named pipe (FIFO).",
    'S' => "is not a socket.",
    'b' => "is not a block special file.",
    'c' => "is not a character special file.",
    'u' => "does not have the setuid bit set.",
    'g' => "does not have the setgid bit set.",
    'k' => "does not have the sticky bit set.",
    'T' => "is not a text file.",
    'B' => "is not a binary file."
);

sub valmess {
    my ( $disposition, $test, $file ) = @_;
    my $ferror;

    if ( $test =~ / ^ (!?) -(\w) \s* $ /x ) {
        my ( $neg, $ftype ) = ( $1, $2 );

        $ferror = "$file $Val_Message{$ftype}";

        if ( $neg eq '!' ) {
            $ferror      =~ s/ is not / should not be /
              || $ferror =~ s/ does not / should not /
              || $ferror =~ s/ not / /;
        }
    }
    else {
        $ferror = "Can't do $test $file.\n";
    }

    die "$ferror\n" if $disposition eq 'die';
    warn "$ferror\n";
}

1;
