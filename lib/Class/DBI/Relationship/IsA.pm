package Class::DBI::Relationship::IsA;

=head1 NAME

Class::DBI::Relationship::IsA - A Class::DBI module for 'Is A' relationships

=head1 DESCRIPTION

Class::DBI::Relationship::IsA Provides an Is A relationship between Class::DBI classes.
This should DTRT when you specify an IsA relationship between classes transparently.
For more information See Class::DBI and Class::DBI::Relationship.

=head1 SYNOPSIS

# in your database (assuming mysql) #

create table person (
  personid int primary key auto_increment,
  firstname varchar(32),
  initials varchar(16),
  surname varchar(64),
  date_of_birth datetime
);

create table artist (
  artistid int primary key auto_increment,
  alias varchar(128),
  person int
);

# in your classes #

package Music::DBI;

use base 'Class::DBI';

Music::DBI->connection('dbi:mysql:dbname', 'username', 'password');

# superclass #

package Music::Person;

use base 'Music::DBI';

Music::Artist->table('person');

Music::Artist->columns(All => qw/personid firstname initials surname date_of_birth/);

# child class #

package Music::Artist;

use base 'Music::DBI';

use Music::Person; # required for access to Music::Person methods

Music::Artist->table('artist');

Music::Artist->columns(All => qw/artistid alias/);

Music::Artist->has_many(cds => 'Music::CD');

Music::Artist->is_a(person => 'Person'); # Music::Artist inherits accessors from Music::Person

# ... elsewhere .. #

use Music::Artist;

my $artist = Music::Artist->create( {firstname=>'Sarah', surname=>'Geller', alias=>'Buffy'});

$artist->initials('M');

$artist->update();

=cut

use strict;
our $VERSION = '0.02';

use warnings;
use base qw( Class::DBI::Relationship );


use Data::Dumper;

sub remap_arguments {
    my $proto = shift;
    my $class = shift;
    $class->_invalid_object_method('is_a()') if ref $class;
    my $column = $class->find_column(+shift)
	or return $class->_croak("is_a needs a valid column");
    my $f_class = shift
	or $class->_croak("$class $column needs an associated class");
    my %meths = @_;
    my @f_cols;
    foreach my $f_col ($f_class->all_columns) {
	push @f_cols, $f_col
	    unless $f_col eq $f_class->primary_column;
    }
    $class->__grouper->add_group(TEMP => map { $_->name } @f_cols);
    $class->mk_classdata('__isa_rels');
    $class->__isa_rels({ });
    return ($class, $column, $f_class, \%meths);
}

sub triggers {
    my $self = shift;
    $self->class->_require_class($self->foreign_class);
    my $column = $self->accessor;
    return (
	    select        => $self->_inflator,
	    before_create => $self->_creator,
            before_update => sub {
                if (my $f_obj = $_[0]->$column()) { $f_obj->update }
            },

    );
}

sub methods {
    my $self = shift;
    $self->class->_require_class($self->foreign_class);

    my $class = $self->class;

    my %methods;
    my $acc_name = $self->accessor->name;
    foreach my $f_col ($self->foreign_class->all_columns) {
        next if $f_col eq $acc_name;
	if ($class->can('pure_accessor_name')) {
	    # provide seperate read/write accessor, read only accessor and write only mutator
	    $methods{ucfirst($class->pure_accessor_name($f_col))}
		= $methods{$class->pure_accessor_name($f_col)} = $self->_get_methods($acc_name, $f_col,'ro');
	    $methods{ucfirst($class->mutator_name($f_col))}
		= $methods{$class->mutator_name($f_col)} = $self->_get_methods($acc_name, $f_col,'wo');
	    $methods{ucfirst($class->accessor_name($f_col))}
		= $methods{$class->accessor_name($f_col)} = $self->_get_methods($acc_name, $f_col,'rw');
	} else {
	    if ( $class->mutator_name($f_col) eq $class->accessor_name($f_col) ) {
		# provide read/write accessor
		$methods{ucfirst($class->accessor_name($f_col))}
		    = $methods{$class->accessor_name($f_col)} = $self->_get_methods($acc_name, $f_col,'rw');
	    } else {
		# provide seperate read only accessor and write only mutator
		$methods{ucfirst($class->accessor_name($f_col))}
		    = $methods{$class->accessor_name($f_col)} = $self->_get_methods($acc_name, $f_col,'ro');
		$methods{ucfirst($class->mutator_name($f_col))}
		    = $methods{$class->mutator_name($f_col)} = $self->_get_methods($acc_name, $f_col,'wo');
	    }
	}
    }

    $methods{search_where} = $self->search_where if $self->class->can('search_where');

    return(
	   %methods,
	   search      => $self->search,
	   search_like => $self->search_like,
	   all_columns => $self->all_columns,
	  );
}

sub search {
    my $self = shift;
    my $SUPER = $self->foreign_class;
    my $col = $self->accessor;
    {
	no strict "refs";
	*{$self->class."::orig_search"} = \&{"Class::DBI::search"};
    }
    return sub {
        my ($self, %args) = (@_);
        my (%child, %parent);
        foreach my $key (keys %args) {
            $child{$key} = $args{$key} if $self->has_real_column($key);
            $parent{$key} = $args{$key} if $SUPER->has_real_column($key);
        }
        if(%parent) {
            return map { $self->orig_search($col => $_->id, %child)
			 } $SUPER->search(%parent);
	} else {
	    return $self->orig_search(%child);
	}
    };
}

sub search_like {
    my $self = shift;
    my $SUPER = $self->foreign_class;
    my $col = $self->accessor;
    {
	no strict "refs";
	*{$self->class."::orig_search_like"} = \&{"Class::DBI::search_like"};
    }
    return sub {
        my ($self, %args) = (@_);
        my (%child, %parent);
        foreach my $key (keys %args) {
            $child{$key} = $args{$key} if $self->has_real_column($key);
            $parent{$key} = $args{$key} if $SUPER->has_real_column($key);
        }
        if(%parent) {
            return map { $self->orig_search_like($col => $_->id, %child)
                       } $SUPER->search_like(%parent);
        } else {
            return $self->orig_search_like(%child);
        }
    };
}

sub search_where {
    my $self = shift;
    my $SUPER = $self->foreign_class;
    my $col = $self->accessor;
    {
        no strict "refs";
        *{$self->class."::orig_search_where"} = \&{"Class::DBI::AbstractSearch::search_where"};
    }

    return sub {
        my ($self, %args) = (@_);
        my (%child, %parent);
        foreach my $key (keys %args) {
            $child{$key} = $args{$key} if $self->has_real_column($key);
            $parent{$key} = $args{$key} if $SUPER->has_real_column($key);
        }
        if(%parent) {
            return map { $self->orig_search_where($col->name => $_->id, %child)
			 } $SUPER->search_where(%parent);
        } else {
            return $self->orig_search_where(%child);
        }
    };
}

sub all_columns {
    my $self = shift;
    my $SUPER = $self->foreign_class;
    my $col = $self->accessor;
    {
	no strict "refs";
	*{$self->class."::orig_all_columns"} = \&{"Class::DBI::all_columns"};
    }
    return sub {
	my $self = shift;
	return ($self->orig_all_columns, $self->columns('TEMP'));
    };
}

sub _creator {
    my $proto = shift;
    my $col = $proto->accessor;

    return sub {
	my $self = shift;
	my $meta = $self->meta_info(is_a => $col);
	my $f_class = $meta->foreign_class;

	my $hash = { };

	foreach ($self->__grouper->group_cols('TEMP')) {
	    next unless defined($self->_attrs($_));
	    $hash->{$_} = $self->_attrs($_);
	}

	my $f_obj = $f_class->create($hash);
	$proto->_import_column_values($self, $f_class, $f_obj);

	return $self->_attribute_store($col => $f_obj);
    };
}

sub _inflator {
    my $proto = shift;
    my $col = $proto->accessor;

    return sub {
	my $self = shift;
	my $value = $self->$col;
	my $meta = $self->meta_info(is_a => $col);
	my $f_class = $meta->foreign_class;

	return if ref($value) and $value->isa($f_class);

	$value = $f_class->_simple_bless($value);
	$proto->_import_column_values($self, $f_class, $value);

	return $self->_attribute_store($col => $value);
    };
}

sub _import_column_values {
    my ($self, $class, $f_class, $f_obj) = (@_);
    foreach ($f_class->all_columns) {
	$class->_attribute_store($_, $f_obj->$_)
	    unless $_->name eq $class->primary_column->name;
    }
}

sub _set_up_class_data {
        my $self = shift;
        $self->class->_extend_class_data(__isa_rels => $self->accessor =>
                        [ $self->foreign_class, %{ $self->args } ]);
        $self->SUPER::_set_up_class_data;
}


sub _get_methods {
    my ($self, $acc_name, $f_col, $mode) = @_;
    my $method;
 MODE: {
	if ($mode eq 'rw') {
	    $method = sub {
		my ($self, @args) = @_;
		if(@args) {
		    $self->$acc_name->$f_col(@args);
		    return;
		}
		else {
		    return $self->$acc_name->$f_col;
		}
	    };
	    last MODE;
	}
	if ($mode eq 'ro') {
	    $method = sub {
		my $self = shift;
		return $self->$acc_name->$f_col;
	    };
	    last MODE;
	}
	if ($mode eq 'wo') {
	    $method =  sub {
		my $self = shift;
		$self->$acc_name->$f_col(@_);
		return;
	    };
	    last MODE;
	}

	else {
	    die "can't get method for mode :$mode\n";
	}
    } # end of MODE
    return $method;
}

################################################################################

=head1 SEE ALSO

L<perl>

Class::DBI

Class::DBI::Relationship

=head1 AUTHOR

Richard Hundt, E<lt>richard@webtk.org.ukE<gt>

=head1 COPYRIGHT

Licensed for use, modification and distribution under the Artistic
and GNU GPL licenses.

Copyright (C) 2004 by Richard Hundt and Aaron Trevena

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.1 or,
at your option, any later version of Perl 5 you may have available.

=cut


################################################################################
################################################################################

1;

