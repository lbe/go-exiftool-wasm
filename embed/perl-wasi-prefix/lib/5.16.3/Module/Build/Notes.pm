package Module::Build::Notes;

use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;
use Data::Dumper;
use IO::File;
use Module::Build::Dumper;

sub new {
    my ( $class, %args ) = @_;
    my $file = delete $args{file}
      or die "Missing required parameter 'file' to new()";
    my $self = bless {
        disk => {},
        new  => {},
        file => $file,
        %args,
    }, $class;
}

sub restore {
    my $self = shift;

    my $fh = IO::File->new("< $self->{file}")
      or die "Can't read $self->{file}: $!";
    $self->{disk} = eval do { local $/; <$fh> };
    die $@ if $@;
    $self->{new} = {};
}

sub access {
    my $self = shift;
    return $self->read() unless @_;

    my $key = shift;
    return $self->read($key) unless @_;

    my $value = shift;
    $self->write( { $key => $value } );
    return $self->read($key);
}

sub has_data {
    my $self = shift;
    return keys %{ $self->read() } > 0;
}

sub exists {
    my ( $self, $key ) = @_;
    return exists( $self->{new}{$key} ) || exists( $self->{disk}{$key} );
}

sub read {
    my $self = shift;

    if (@_) {
        my $key = shift;
        return $self->{new}{$key} if exists $self->{new}{$key};
        return $self->{disk}{$key};
    }

    my $out = (
        keys %{ $self->{new} }
        ? { %{ $self->{disk} }, %{ $self->{new} } }
        : $self->{disk}
    );
    return wantarray ? %$out : $out;
}

sub _same {
    my ( $self, $x, $y ) = @_;
    return 1 if !defined($x) and !defined($y);
    return 0 if !defined($x) or !defined($y);
    return $x eq $y;
}

sub write {
    my ( $self, $href ) = @_;
    $href ||= {};

    @{ $self->{new} }{ keys %$href } = values %$href;

    foreach my $key ( keys %{ $self->{new} } ) {
        next if ref $self->{new}{$key};
        next if ref $self->{disk}{$key} or !exists $self->{disk}{$key};
        delete $self->{new}{$key}
          if $self->_same( $self->{new}{$key}, $self->{disk}{$key} );
    }

    if ( my $file = $self->{file} ) {
        my ( $vol, $dir, $base ) = File::Spec->splitpath($file);
        $dir = File::Spec->catpath( $vol, $dir, '' );
        return unless -e $dir && -d $dir;

        return if -e $file and !keys %{ $self->{new} };

        @{ $self->{disk} }{ keys %{ $self->{new} } } = values %{ $self->{new} };
        $self->_dump( $file, $self->{disk} );

        $self->{new} = {};
    }
    return $self->read;
}

sub _dump {
    my ( $self, $file, $data ) = @_;

    my $fh = IO::File->new("> $file") or die "Can't create '$file': $!";
    print {$fh} Module::Build::Dumper->_data_dump($data);
}

my $orig_template = do { local $/; <DATA> };
close DATA;

sub write_config_data {
    my ( $self, %args ) = @_;

    my $template = $orig_template;
    $template =~ s/NOTES_NAME/$args{config_module}/g;
    $template =~ s/MODULE_NAME/$args{module}/g;
    $template =~ s/=begin private\n//;
    $template =~ s/=end private/=cut/;

    $template =~ s{$_\n}{} for '=begin private', '=end private';

    my $fh = IO::File->new("> $args{file}")
      or die "Can't create '$args{file}': $!";
    print {$fh} $template;
    print {$fh} "\n__DATA__\n";
    print {$fh}
      Module::Build::Dumper->_data_dump(
        [ $args{config_data}, $args{feature}, $args{auto_features} ] );

}

1;


__DATA__
package NOTES_NAME;
use strict;
my $arrayref = eval do {local $/; <DATA>}
  or die "Couldn't load ConfigData data: $@";
close DATA;
my ($config, $features, $auto_features) = @$arrayref;

sub config { $config->{$_[1]} }

sub set_config { $config->{$_[1]} = $_[2] }
sub set_feature { $features->{$_[1]} = 0+!!$_[2] }  # Constrain to 1 or 0

sub auto_feature_names { grep !exists $features->{$_}, keys %$auto_features }

sub feature_names {
  my @features = (keys %$features, auto_feature_names());
  @features;
}

sub config_names  { keys %$config }

sub write {
  my $me = __FILE__;
  require IO::File;

  # Can't use Module::Build::Dumper here because M::B is only a
  # build-time prereq of this module
  require Data::Dumper;

  my $mode_orig = (stat $me)[2] & 07777;
  chmod($mode_orig | 0222, $me); # Make it writeable
  my $fh = IO::File->new($me, 'r+') or die "Can't rewrite $me: $!";
  seek($fh, 0, 0);
  while (<$fh>) {
    last if /^__DATA__$/;
  }
  die "Couldn't find __DATA__ token in $me" if eof($fh);

  seek($fh, tell($fh), 0);
  my $data = [$config, $features, $auto_features];
  $fh->print( 'do{ my '
	      . Data::Dumper->new([$data],['x'])->Purity(1)->Dump()
	      . '$x; }' );
  truncate($fh, tell($fh));
  $fh->close;

  chmod($mode_orig, $me)
    or warn "Couldn't restore permissions on $me: $!";
}

sub feature {
  my ($package, $key) = @_;
  return $features->{$key} if exists $features->{$key};

  my $info = $auto_features->{$key} or return 0;

  # Under perl 5.005, each(%$foo) isn't working correctly when $foo
  # was reanimated with Data::Dumper and eval().  Not sure why, but
  # copying to a new hash seems to solve it.
  my %info = %$info;

  require Module::Build;  # XXX should get rid of this
  while (my ($type, $prereqs) = each %info) {
    next if $type eq 'description' || $type eq 'recommends';

    my %p = %$prereqs;  # Ditto here.
    while (my ($modname, $spec) = each %p) {
      my $status = Module::Build->check_installed_status($modname, $spec);
      if ((!$status->{ok}) xor ($type =~ /conflicts$/)) { return 0; }
      if ( ! eval "require $modname; 1" ) { return 0; }
    }
  }
  return 1;
}

