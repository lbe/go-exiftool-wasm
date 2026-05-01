package Locale::Codes;

use strict;
use warnings;
require 5.002;

use Carp;
use Locale::Codes::Constants;

our ( $VERSION, %Data, %Retired );

$VERSION = '3.21';

sub _code {
    return 1 if ( @_ > 3 );

    my ( $type, $code, $codeset ) = @_;
    $code = '' if ( !$code );

    $codeset = $ALL_CODESETS{$type}{'default'}
      if ( !defined($codeset) || $codeset eq '' );
    $codeset = lc($codeset);
    return 1 if ( !exists $ALL_CODESETS{$type}{'codesets'}{$codeset} );
    return ( 0, $code, $codeset ) if ( !$code );

    my ( $op, @args ) = @{ $ALL_CODESETS{$type}{'codesets'}{$codeset} };

    if ( $op eq 'lc' ) {
        $code = lc($code);

    }
    elsif ( $op eq 'uc' ) {
        $code = uc($code);

    }
    elsif ( $op eq 'ucfirst' ) {
        $code = ucfirst( lc($code) );

    }
    elsif ( $op eq 'numeric' ) {
        return (1) unless ( $code =~ /^\d+$/ );
        my $l = $args[0];
        $code = sprintf( "%.${l}d", $code );
    }

    return ( 0, $code, $codeset );
}

sub _code2name {
    my ( $type, @args ) = @_;
    my $retired = 0;
    if ( @args > 0 && $args[$#args] && $args[$#args] eq 'retired' ) {
        pop(@args);
        $retired = 1;
    }

    my ( $err, $code, $codeset ) = _code( $type, @args );
    return undef if ( $err
        || !defined $code );

    $code = $Data{$type}{'codealias'}{$codeset}{$code}
      if ( exists $Data{$type}{'codealias'}{$codeset}{$code} );

    if (   exists $Data{$type}{'code2id'}{$codeset}
        && exists $Data{$type}{'code2id'}{$codeset}{$code} )
    {
        my ( $id, $i ) = @{ $Data{$type}{'code2id'}{$codeset}{$code} };
        my $name = $Data{$type}{'id2names'}{$id}[$i];
        return $name;

    }
    elsif ( $retired && exists $Retired{$type}{$codeset}{'code'}{$code} ) {
        return $Retired{$type}{$codeset}{'code'}{$code};

    }
    else {
        return undef;
    }
}

sub _name2code {
    my ( $type, $name, @args ) = @_;
    return undef if ( !$name );
    $name = lc($name);

    my $retired = 0;
    if ( @args > 0 && $args[$#args] && $args[$#args] eq 'retired' ) {
        pop(@args);
        $retired = 1;
    }

    my ( $err, $tmp, $codeset ) = _code( $type, '', @args );
    return undef if ($err);

    if ( exists $Data{$type}{'alias2id'}{$name} ) {
        my $id = $Data{$type}{'alias2id'}{$name}[0];
        if ( exists $Data{$type}{'id2code'}{$codeset}{$id} ) {
            return $Data{$type}{'id2code'}{$codeset}{$id};
        }

    }
    elsif ( $retired && exists $Retired{$type}{$codeset}{'name'}{$name} ) {
        return $Retired{$type}{$codeset}{'name'}{$name}[0];
    }

    return undef;
}

sub _code2code {
    my ( $type, @args ) = @_;
    ( @args == 3 ) or croak "${type}_code2code() takes 3 arguments!";

    my ( $code, $inset, $outset ) = @args;
    my ( $err, $tmp );
    ( $err, $code, $inset ) = _code( $type, $code, $inset );
    return undef if ($err);
    ( $err, $tmp, $outset ) = _code( $type, '', $outset );
    return undef if ($err);

    my $name = _code2name( $type, $code, $inset );
    my $outcode = _name2code( $type, $name, $outset );
    return $outcode;
}

sub _all_codes {
    my ( $type, @args ) = @_;
    my $retired = 0;
    if ( @args > 0 && $args[$#args] && $args[$#args] eq 'retired' ) {
        pop(@args);
        $retired = 1;
    }

    my ( $err, $tmp, $codeset ) = _code( $type, '', @args );
    return () if ($err);

    if ( !exists $Data{$type}{'code2id'}{$codeset} ) {
        return ();
    }
    my @codes = keys %{ $Data{$type}{'code2id'}{$codeset} };
    push( @codes, keys %{ $Retired{$type}{$codeset}{'code'} } ) if ($retired);
    return ( sort @codes );
}

sub _all_names {
    my ( $type, @args ) = @_;
    my $retired = 0;
    if ( @args > 0 && $args[$#args] && $args[$#args] eq 'retired' ) {
        pop(@args);
        $retired = 1;
    }

    my ( $err, $tmp, $codeset ) = _code( $type, '', @args );
    return () if ($err);

    my @codes = _all_codes( $type, $codeset );
    my @names;

    foreach my $code (@codes) {
        my ( $id, $i ) = @{ $Data{$type}{'code2id'}{$codeset}{$code} };
        my $name = $Data{$type}{'id2names'}{$id}[$i];
        push( @names, $name );
    }
    if ($retired) {
        foreach my $lc ( keys %{ $Retired{$type}{$codeset}{'name'} } ) {
            my $name = $Retired{$type}{$codeset}{'name'}{$lc}[1];
            push @names, $name;
        }
    }
    return ( sort @names );
}

sub _rename {
    my ( $type, $code, $new_name, @args ) = @_;

    my $nowarn = 0;
    $nowarn = 1, pop(@args) if ( @args && $args[$#args] eq "nowarn" );

    my $codeset = shift(@args);
    my $err;
    ( $err, $code, $codeset ) = _code( $type, $code, $codeset );

    if ( !$codeset ) {
        carp "rename_$type(): unknown codeset\n" unless ($nowarn);
        return 0;
    }

    $code = $Data{$type}{'codealias'}{$codeset}{$code}
      if ( exists $Data{$type}{'codealias'}{$codeset}{$code} );

    my $id;
    if ( exists $Data{$type}{'code2id'}{$codeset}{$code} ) {
        $id = $Data{$type}{'code2id'}{$codeset}{$code}[0];
    }
    else {
        carp "rename_$type(): unknown code: $code\n" unless ($nowarn);
        return 0;
    }

    if ( exists $Data{$type}{'alias2id'}{ lc($new_name) } ) {

        my ( $new_id, $i ) = @{ $Data{$type}{'alias2id'}{ lc($new_name) } };
        if ( $new_id != $id ) {
            carp "rename_$type(): rename to an existing $type not allowed\n"
              unless ($nowarn);
            return 0;
        }

        $Data{$type}{'code2id'}{$codeset}{$code}[1] = $i;

    }
    else {

        push @{ $Data{$type}{'id2names'}{$id} }, $new_name;
        my $i = $#{ $Data{$type}{'id2names'}{$id} };
        $Data{$type}{'alias2id'}{ lc($new_name) } = [ $id, $i ];
        $Data{$type}{'code2id'}{$codeset}{$code}[1] = $i;
    }

    return 1;
}

sub _add_code {
    my ( $type, $code, $name, @args ) = @_;

    my $nowarn = 0;
    $nowarn = 1, pop(@args) if ( @args && $args[$#args] eq "nowarn" );

    my $codeset = shift(@args);
    my $err;
    ( $err, $code, $codeset ) = _code( $type, $code, $codeset );

    if ( !$codeset ) {
        carp "add_$type(): unknown codeset\n" unless ($nowarn);
        return 0;
    }

    if (   exists $Data{$type}{'code2id'}{$codeset}{$code}
        || exists $Data{$type}{'codealias'}{$codeset}{$code} )
    {
        carp "add_$type(): code already in use: $code\n" unless ($nowarn);
        return 0;
    }

    my ( $id, $i );
    if ( exists $Data{$type}{'alias2id'}{ lc($name) } ) {
        ( $id, $i ) = @{ $Data{$type}{'alias2id'}{ lc($name) } };
        if ( exists $Data{$type}{'id2code'}{$codeset}{$id} ) {
            carp "add_$type(): name already in use: $name\n" unless ($nowarn);
            return 0;
        }

    }
    else {
        $id = $Data{$type}{'id'}++;
        $i  = 0;
        $Data{$type}{'alias2id'}{ lc($name) } = [ $id, $i ];
        $Data{$type}{'id2names'}{$id} = [$name];
    }

    $Data{$type}{'code2id'}{$codeset}{$code} = [ $id, $i ];
    $Data{$type}{'id2code'}{$codeset}{$id} = $code;

    return 1;
}

sub _delete_code {
    my ( $type, $code, @args ) = @_;

    my $nowarn = 0;
    $nowarn = 1, pop(@args) if ( @args && $args[$#args] eq "nowarn" );

    my $codeset = shift(@args);
    my $err;
    ( $err, $code, $codeset ) = _code( $type, $code, $codeset );

    if ( !$codeset ) {
        carp "delete_$type(): unknown codeset\n" unless ($nowarn);
        return 0;
    }

    $code = $Data{$type}{'codealias'}{$codeset}{$code}
      if ( exists $Data{$type}{'codealias'}{$codeset}{$code} );

    if ( !exists $Data{$type}{'code2id'}{$codeset}{$code} ) {
        carp "delete_$type(): code does not exist: $code\n" unless ($nowarn);
        return 0;
    }

    my $id = $Data{$type}{'code2id'}{$codeset}{$code}[0];
    delete $Data{$type}{'code2id'}{$codeset}{$code};
    delete $Data{$type}{'id2code'}{$codeset}{$id};

    foreach my $alias ( keys %{ $Data{$type}{'codealias'}{$codeset} } ) {
        next if ( $Data{$type}{'codealias'}{$codeset}{$alias} ne $code );
        delete $Data{$type}{'codealias'}{$codeset}{$alias};
    }

    foreach my $c ( keys %{ $Data{$type}{'id2code'} } ) {
        return 1 if ( exists $Data{$type}{'id2code'}{$c}{$id} );
    }

    my @names = @{ $Data{$type}{'id2names'}{$id} };
    delete $Data{$type}{'id2names'}{$id};

    foreach my $name (@names) {
        delete $Data{$type}{'alias2id'}{ lc($name) };
    }

    return 1;
}

sub _add_alias {
    my ( $type, $name, $new_name, $nowarn ) = @_;

    $nowarn = ( defined($nowarn) && $nowarn eq "nowarn" ? 1 : 0 );

    my ($id);
    if ( exists $Data{$type}{'alias2id'}{ lc($name) } ) {
        $id = $Data{$type}{'alias2id'}{ lc($name) }[0];
    }
    else {
        carp "add_${type}_alias(): name does not exist: $name\n"
          unless ($nowarn);
        return 0;
    }

    if ( exists $Data{$type}{'alias2id'}{ lc($new_name) } ) {
        carp "add_${type}_alias(): alias already in use: $new_name\n"
          unless ($nowarn);
        return 0;
    }

    push @{ $Data{$type}{'id2names'}{$id} }, $new_name;
    my $i = $#{ $Data{$type}{'id2names'}{$id} };
    $Data{$type}{'alias2id'}{ lc($new_name) } = [ $id, $i ];

    return 1;
}

sub _delete_alias {
    my ( $type, $name, $nowarn ) = @_;

    $nowarn = ( defined($nowarn) && $nowarn eq "nowarn" ? 1 : 0 );

    my ( $id, $i );
    if ( exists $Data{$type}{'alias2id'}{ lc($name) } ) {
        ( $id, $i ) = @{ $Data{$type}{'alias2id'}{ lc($name) } };
    }
    else {
        carp "delete_${type}_alias(): name does not exist: $name\n"
          unless ($nowarn);
        return 0;
    }

    my $n = $#{ $Data{$type}{'id2names'}{$id} };
    if ( $n == 1 ) {
        carp
"delete_${type}_alias(): only one name defined (use _delete_${type} instead)\n"
          unless ($nowarn);
        return 0;
    }

    splice( @{ $Data{$type}{'id2names'}{$id} }, $i, 1 );
    delete $Data{$type}{'alias2id'}{ lc($name) };

    foreach my $codeset ( keys %{ $Data{'code2id'} } ) {
        foreach my $code ( keys %{ $Data{'code2id'}{$codeset} } ) {
            my ( $jd, $j ) = @{ $Data{'code2id'}{$codeset}{$code} };
            next if ( $jd ne $id
                || $j < $i );
            if ( $i == $j ) {
                $Data{'code2id'}{$codeset}{$code}[1] = 0;
            }
            else {
                $Data{'code2id'}{$codeset}{$code}[1]--;
            }
        }
    }

    return 1;
}

sub _rename_code {
    my ( $type, $code, $new_code, @args ) = @_;

    my $nowarn = 0;
    $nowarn = 1, pop(@args) if ( @args && $args[$#args] eq "nowarn" );

    my $codeset = shift(@args);
    my $err;
    ( $err, $code,     $codeset ) = _code( $type, $code,     $codeset );
    ( $err, $new_code, $codeset ) = _code( $type, $new_code, $codeset )
      if ( !$err );

    if ( !$codeset ) {
        carp "rename_$type(): unknown codeset\n" unless ($nowarn);
        return 0;
    }

    $code = $Data{$type}{'codealias'}{$codeset}{$code}
      if ( exists $Data{$type}{'codealias'}{$codeset}{$code} );

    if ( !exists $Data{$type}{'code2id'}{$codeset}{$code} ) {
        carp "rename_$type(): unknown code: $code\n" unless ($nowarn);
        return 0;
    }

    if ( exists $Data{$type}{'codealias'}{$codeset}{$new_code} ) {
        if ( $Data{$type}{'codealias'}{$codeset}{$new_code} eq $code ) {

            delete $Data{$type}{'codealias'}{$codeset}{$new_code};

        }
        else {
            carp "rename_$type(): new code already in use: $new_code\n"
              unless ($nowarn);
            return 0;
        }

    }
    elsif ( exists $Data{$type}{'code2id'}{$codeset}{$new_code} ) {
        carp "rename_$type(): new code already in use: $new_code\n"
          unless ($nowarn);
        return 0;
    }

    $Data{$type}{'codealias'}{$codeset}{$code} = $new_code;

    my $id = $Data{$type}{'code2id'}{$codeset}{$code}[0];
    $Data{$type}{'code2id'}{$codeset}{$new_code} =
      $Data{$type}{'code2id'}{$codeset}{$code};
    delete $Data{$type}{'code2id'}{$codeset}{$code};

    $Data{$type}{'id2code'}{$codeset}{$id} = $new_code;

    return 1;
}

sub _add_code_alias {
    my ( $type, $code, $new_code, @args ) = @_;

    my $nowarn = 0;
    $nowarn = 1, pop(@args) if ( @args && $args[$#args] eq "nowarn" );

    my $codeset = shift(@args);
    my $err;
    ( $err, $code,     $codeset ) = _code( $type, $code,     $codeset );
    ( $err, $new_code, $codeset ) = _code( $type, $new_code, $codeset )
      if ( !$err );

    if ( !$codeset ) {
        carp "add_${type}_code_alias(): unknown codeset\n" unless ($nowarn);
        return 0;
    }

    $code = $Data{$type}{'codealias'}{$codeset}{$code}
      if ( exists $Data{$type}{'codealias'}{$codeset}{$code} );

    if ( !exists $Data{$type}{'code2id'}{$codeset}{$code} ) {
        carp "add_${type}_code_alias(): unknown code: $code\n" unless ($nowarn);
        return 0;
    }

    if (   exists $Data{$type}{'code2id'}{$codeset}{$new_code}
        || exists $Data{$type}{'codealias'}{$codeset}{$new_code} )
    {
        carp "add_${type}_code_alias(): code already in use: $new_code\n"
          unless ($nowarn);
        return 0;
    }

    $Data{$type}{'codealias'}{$codeset}{$new_code} = $code;

    return 1;
}

sub _delete_code_alias {
    my ( $type, $code, @args ) = @_;

    my $nowarn = 0;
    $nowarn = 1, pop(@args) if ( @args && $args[$#args] eq "nowarn" );

    my $codeset = shift(@args);
    my $err;
    ( $err, $code, $codeset ) = Locale::Codes::_code( $type, $code, $codeset );

    if ( !$codeset ) {
        carp "delete_${type}_code_alias(): unknown codeset\n" unless ($nowarn);
        return 0;
    }

    if ( !exists $Data{$type}{'codealias'}{$codeset}{$code} ) {
        carp "delete_${type}_code_alias(): no alias defined: $code\n"
          unless ($nowarn);
        return 0;
    }

    delete $Data{$type}{'codealias'}{$codeset}{$code};

    return 1;
}

1;
