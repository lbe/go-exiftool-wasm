package Module::Build::Platform::MacOS;

use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;
use Module::Build::Base;
use vars qw(@ISA);
@ISA = qw(Module::Build::Base);

use ExtUtils::Install;

sub have_forkpipe { 0 }

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    foreach ( 'sitelib', 'sitearch' ) {
        $self->config( $_ => $self->config("install$_") )
          unless $self->config($_);
    }

    ( my $sp = $self->config('startperl') ) =~ s/.*Exit \{Status\}\s//;
    $self->config( startperl => $sp );

    return $self;
}

sub make_executable {
    my $self = shift;
    require MacPerl;
    foreach (@_) {
        MacPerl::SetFileInfo( 'McPL', 'TEXT', $_ );
    }
}

sub dispatch {
    my $self = shift;

    if ( !@_ and !@ARGV ) {
        require MacPerl;

        my @action_list = qw(build test install);
        my %actions = map { +( $_, 1 ) } $self->known_actions;
        delete @actions{@action_list};
        push @action_list, sort { $a cmp $b } keys %actions;

        my %toolserver = map { +$_ => 1 } qw(test disttest diff testdb);
        foreach (@action_list) {
            $_ .= ' *' if $toolserver{$_};
        }

        my $cmd =
          MacPerl::Pick( "What build command? ('*' requires ToolServer)",
            @action_list );
        return unless defined $cmd;
        $cmd =~ s/ \*$//;
        $ARGV[0] = ($cmd);

        my $args = MacPerl::Ask( 'Any extra arguments?  (ie. verbose=1)', '' );
        return unless defined $args;
        push @ARGV, $self->split_like_shell($args);
    }

    $self->SUPER::dispatch(@_);
}

sub ACTION_realclean {
    my $self = shift;
    chmod 0666, $self->{properties}{build_script};
    $self->SUPER::ACTION_realclean;
}

sub ACTION_install {
    my $self = shift;

    return $self->SUPER::ACTION_install(@_)
      if eval { ExtUtils::Install->VERSION('1.30'); 1 };

    local $^W                      = 0;
    local *ExtUtils::Install::find = sub {
        my ( $code, @dirs ) = @_;

        @dirs = map { $_ eq '.' ? File::Spec->curdir : $_ } @dirs;

        return File::Find::find( $code, @dirs );
    };

    return $self->SUPER::ACTION_install(@_);
}

1;
__END__

