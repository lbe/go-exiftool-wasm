package Term::UI;

use Carp;
use Params::Check qw[check allow];
use Term::ReadLine;
use Locale::Maketext::Simple Style => 'gettext';
use Term::UI::History;

use strict;

BEGIN {
    use vars qw[$VERSION $AUTOREPLY $VERBOSE $INVALID];
    $VERBOSE = 1;
    $VERSION = '0.30';
    $INVALID = loc('Invalid selection, please try again: ');
}

push @Term::ReadLine::Stub::ISA, __PACKAGE__
  unless grep { $_ eq __PACKAGE__ } @Term::ReadLine::Stub::ISA;


sub get_reply {
    my $term = shift;
    my %hash = @_;

    my $tmpl = {
        default => { default => undef, strict_type => 1 },
        prompt  => { default => '',    strict_type => 1, required => 1 },
        choices => { default => [],    strict_type => 1 },
        multi => { default => 0, allow => [ 0, 1 ] },
        allow => { default => qr/.*/ },
        print_me => { default => '', strict_type => 1 },
    };

    my $args = check( $tmpl, \%hash, $VERBOSE )
      or ( carp( loc(q[Could not parse arguments]) ), return );

    my $prompt_add;

    if ( @{ $args->{choices} } ) {
        my $i;

        for my $choice ( @{ $args->{choices} } ) {
            $i++;
            
            $prompt_add = $i
              if ( defined $args->{default} and $choice eq $args->{default} );

            $args->{print_me} .= sprintf "\n%3s> %-s", $i, $choice;
        }

        $args->{print_me} .= "\n" if $i;

        $args->{allow} = $args->{choices};

    }
    elsif ( defined $args->{default} ) {
        $prompt_add = $args->{default};
    }

    return $term->_tt_readline( %$args, prompt_add => $prompt_add );

}


sub ask_yn {
    my $term = shift;
    my %hash = @_;

    my $tmpl = {
        default => {
            default     => undef,
            allow       => [qw|0 1 y n|],
            strict_type => 1
        },
        prompt   => { default => '', required    => 1, strict_type => 1 },
        print_me => { default => '', strict_type => 1 },
        multi    => { default => 0,  no_override => 1 },
        choices => { default => [qw|y n|], no_override => 1 },
        allow   => {
            default     => [ qr/^y(?:es)?$/i, qr/^n(?:o)?$/i ],
            no_override => 1
        },
    };

    my $args = check( $tmpl, \%hash, $VERBOSE ) or return undef;

    my $prompt_add;
    {
        my @list = @{ $args->{choices} };
        if ( defined $args->{default} ) {

            $args->{default} =
              $args->{default} =~ /\d/
              ? { 0 => 'n', 1 => 'y' }->{ $args->{default} }
              : $args->{default};

            @list =
              map { lc $args->{default} eq lc $_ ? uc $args->{default} : $_ }
              @list;
        }

        $prompt_add .= join( "/", @list );
    }

    my $rv = $term->_tt_readline( %$args, prompt_add => $prompt_add );

    return $rv =~ /^y/i ? 1 : 0;
}

sub _tt_readline {
    my $term = shift;
    my %hash = @_;

    local $Params::Check::VERBOSE = 0;
    local $|                      = 1;

    my ( $default, $prompt, $choices, $multi, $allow, $prompt_add, $print_me );
    my $tmpl = {
        default => {
            default     => undef,
            strict_type => 1,
            store       => \$default
        },
        prompt => {
            default     => '',
            strict_type => 1,
            required    => 1,
            store       => \$prompt
        },
        choices => {
            default     => [],
            strict_type => 1,
            store       => \$choices
        },
        multi => { default => 0, allow => [ 0, 1 ], store => \$multi },
        allow      => { default => qr/.*/, store => \$allow, },
        prompt_add => { default => '',     store => \$prompt_add },
        print_me   => { default => '',     store => \$print_me },
    };

    check( $tmpl, \%hash, $VERBOSE ) or return;

    history($print_me) if $print_me;

    $prompt .= " [$prompt_add]: " if $prompt_add;

    if ($AUTOREPLY) {

        carp loc( q[You have '%1' set to true, but did not provide a default!],
            '$AUTOREPLY' )
          if ( !defined $default && $VERBOSE );

        history( join ' ', grep { defined } $prompt, $default );

        return $default;
    }

  LOOP: {

        {
            my @lines = split "\n", $prompt;
            $prompt = pop @lines;

            history("$_\n") for @lines;
        }

        my $answer = $term->readline($prompt);
        $answer = $default unless length $answer;

        $term->addhistory($answer) if length $answer;

        history( "$prompt $answer", 0 );

        my @answers = $multi ? split( /\s+/, $answer ) : $answer;

        my @rv;

        if (@$choices) {

            for my $answer (@answers) {

                if ( $answer =~ /\D/ ) {
                    push @rv, $answer if allow( $answer, $allow );
                }
                else {

                    push @rv, $choices->[ $answer - 1 ]
                      if $answer > 0 && defined $choices->[ $answer - 1 ];
                }
            }

        }
        else {
            push @rv,
              grep { allow( $_, $allow ) }
              scalar @answers ? @answers : ($default);
        }

        if (   ( @rv != @answers )
            or ( scalar(@$choices) and not scalar(@answers) ) )
        {
            $prompt = $INVALID;
            $prompt .= "[$prompt_add] " if $prompt_add;
            redo LOOP;

        }
        else {
            return $multi ? @rv : $rv[0];
        }
    }
}


sub parse_options {
    my $term  = shift;
    my $input = shift;

    my $return = {};

    while ($input =~ s/(?:^|\s+)--?([-\w]+=("|').+?\2)(?=\Z|\s+)//
        or $input =~ s/(?:^|\s+)--?([-\w]+=\S+)(?=\Z|\s+)//
        or $input =~ s/(?:^|\s+)--?([-\w]+)(?=\Z|\s+)// )
    {
        my $match = $1;

        if ( $match =~ /^([-\w]+)=("|')(.+?)\2$/ ) {
            $return->{$1} = $3;

        }
        elsif ( $match =~ /^([-\w]+)=(\S+)$/ ) {
            $return->{$1} = $2;

        }
        elsif ( $match =~ /^no-?([-\w]+)$/i ) {
            $return->{$1} = 0;

        }
        elsif ( $match =~ /^([-\w]+)$/ ) {
            $return->{$1} = 1;

        }
        else {
            carp( loc( q[I do not understand option "%1"\n], $match ) )
              if $VERBOSE;
        }
    }

    return wantarray ? ( $return, $input ) : $return;
}


sub history_as_string { return Term::UI::History->history_as_string }

1;

