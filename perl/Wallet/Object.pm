# Wallet::Object -- Parent class for any object stored in the wallet.
# $Id$
#
# Written by Russ Allbery <rra@stanford.edu>
# Copyright 2007 Board of Trustees, Leland Stanford Jr. University
#
# See README for licensing terms.

##############################################################################
# Modules and declarations
##############################################################################

package Wallet::Object;
require 5.006;

use strict;
use vars qw($VERSION);

use DBI;

# This version should be increased on any code change to this module.  Always
# use two digits for the minor version with a leading zero if necessary so
# that it will sort properly.
$VERSION = '0.01';

##############################################################################
# Constructors
##############################################################################

# Initialize an object from the database.  Verifies that the object already
# exists with the given type, and if it does, returns a new blessed object of
# the specified class.  Stores the database handle to use, the name, and the
# type in the object.  If the object doesn't exist, returns undef.  This will
# probably be usable as-is by most object types.
sub new {
    my ($class, $name, $type, $dbh) = shift;
    $dbh->{AutoCommit} = 0;
    $dbh->{RaiseError} = 1;
    $dbh->{PrintError} = 0;
    my $sql = 'select ob_name from objects where ob_name = ? and ob_type = ?';
    my $data = $dbh->selectrow_array ($sql, undef, $name, $type);
    return undef unless ($data and $data eq $name);
    my $self = {
        dbh  => $dbh,
        name => $name,
        type => $type,
    };
    bless ($self, $class);
    return $self;
}

# Create a new object in the database of the specified name and type, setting
# the ob_created_* fields accordingly, and returns a new blessed object of the
# specified class.  Stores the database handle to use, the name, and the type
# in the object.  Subclasses may need to override this to do additional setup.
sub create {
    my ($class, $name, $type, $dbh, $user, $host, $time) = @_;
    $dbh->{AutoCommit} = 0;
    $dbh->{RaiseError} = 1;
    $dbh->{PrintError} = 0;
    $time ||= time;
    eval {
        my $sql = 'insert into objects (ob_name, ob_type, ob_created_by,
            ob_created_from, ob_created_on) values (?, ?, ?, ?, ?)';
        $dbh->do ($sql, undef, $name, $type, $user, $host, $time);
        my $sql = "insert into object_history (oh_object, oh_type, oh_action,
            oh_by, oh_from, oh_on) values (?, ?, 'create', ?, ?, ?)";
        $self->{dbh}->do ($sql, undef, $name, $type, $user, $host, $time);
        $dbh->commit;
    };
    if ($@) {
        $dbh->rollback;
        return undef;
    }
    my $self = {
        dbh  => $dbh,
        name => $name,
        type => $type,
    };
    bless ($self, $class);
    return $self;
}

##############################################################################
# Utility functions
##############################################################################

# Returns the current error message of the object, if any.
sub error {
    my ($self) = @_;
    return $self->{error};
}

# Record a global object action for this object.  Takes the action (which must
# be one of get or store), and the trace information: user, host, and time.
# Returns true on success and false on failure, setting error appropriately.
#
# This function commits its transaction when complete and should not be called
# inside another transaction.
sub log_action {
    my ($self, $action, $user, $host, $time) = @_;
    unless ($action =~ /^(get|store)\z/) {
        $self->{error} = "invalid history action $action";
        return undef;
    }

    # We have two traces to record, one in the object_history table and one in
    # the object record itself.  Commit both changes as a transaction.  We
    # assume that AutoCommit is turned off.
    eval {
        my $sql = 'insert into object_history (oh_object, oh_type, oh_action,
            oh_by, oh_from, oh_on) values (?, ?, ?, ?, ?, ?)';
        $self->{dbh}->do ($sql, undef, $self->{name}, $self->{type}, $action,
                          $user, $host, $time);
        if ($action eq 'get') {
            $sql = 'update objects set ob_downloaded_by = ?,
                ob_downloaded_from = ?, ob_downloaded_on = ? where
                ob_name = ? and ob_type = ?';
            $self->{dbh}->do ($sql, undef, $user, $host, $time, $self->{name},
                              $self->{type});
        } elsif ($action eq 'store') {
            $sql = 'update objects set ob_stored_by = ?, ob_stored_from = ?,
                ob_stored_on = ? where ob_name = ? and ob_type = ?';
            $self->{dbh}->do ($sql, undef, $user, $host, $time, $self->{name},
                              $self->{type});
        }
        $self->{dbh}->commit;
    };
    if ($@) {
        my $id = $self->{type} . ':' . $self->{name};
        $self->{error} = "cannot update history for $id: $@";
        $self->{dbh}->rollback;
        return undef;
    }
    return 1;
}

# Record a setting change for this object.  Takes the field, the old value,
# the new value, and the trace information (user, host, and time).  The field
# may have the special value "type_data <field>" in which case the value after
# the whitespace is used as the type_field value.
#
# This function does not commit and does not catch exceptions.  It should
# normally be called as part of a larger transaction that implements the
# setting change and should be committed with that change.
sub log_set {
    my ($self, $field, $old, $new, $user, $host, $time) = @_;
    my $type_field;
    if ($field =~ /^type_data\s+/) {
        ($field, $type_field) = split (' ', $field, 2);
    }
    my %fields = map { $_ => 1 }
        qw(owner acl_get acl_store acl_show acl_destroy acl_flags expires
           flags type_data);
    unless ($fields{$field}) {
        die "invalid history field $field";
    }
    my $sql = "insert into object_history (oh_object, oh_type, oh_action,
        oh_field, oh_type_field, oh_from, oh_to, oh_by, oh_from, oh_on)
        values (?, ?, 'set', ?, ?, ?, ?, ?, ?, ?)";
    $self->{dbh}->do ($sql, undef, $self->{name}, $self->{type}, $field,
                      $type_field, $old, $new, $user, $host, $time);
}

##############################################################################
# Get/set values
##############################################################################

# Set a particular attribute.  Takes the attribute to set and its new value.
# Returns undef on failure and the new value on success.
sub _set_internal {
    my ($self, $attr, $value, $user, $host, $time) = @_;
    $time ||= time;
    my $name = $self->{name};
    my $type = $self->{type};
    eval {
        my $sql = "select ob_$attr from objects where ob_name = ? and
            ob_type = ?";
        my $old = $self->{dbh}->selectrow_array ($sql, undef, $name, $type);
        $sql = "update objects set ob_$attr = ? where ob_name = ? and
            ob_type = ?";
        $self->{dbh}->do ($sql, undef, $value, $name, $type);
        $self->log_set ($attr, $old, $value, $user, $host, $time);
        $self->{dbh}->commit;
    };
    if ($@) {
        my $id = $self->{type} . ':' . $self->{name};
        $self->{error} = "cannot set $attr on $id: $@";
        $self->{dbh}->rollback;
        return;
    }
    return $value;
}

# Get a particular attribute.  Returns the attribute value.
sub _get_internal {
    my ($self, $attr) = @_;
    my $name = $self->{name};
    my $type = $self->{type};
    my $sql = "select $attr from objects where ob_name = ? and ob_type = ?";
    my $value = $self->{dbh}->selectrow_array ($sql, undef, $name, $type);
    return $value;
}

# Get or set the owner of an object.  If setting it, trace information must
# also be provided.
sub owner {
    my ($self, $owner, $user, $host, $time) = @_;
    if ($owner) {
        if ($owner !~ /^\d+\z/) {
            $self->{error} = "malformed owner ACL id $owner";
            return;
        }
        return $self->_set_internal ('owner', $owner, $user, $host, $time);
    } else {
        return $self->_get_internal ('owner');
    }
}

# Get or set an ACL on an object.  Takes the type of ACL and, if setting, the
# new ACL identifier.  If setting it, trace information must also be provided.
sub acl {
    my ($self, $type, $acl, $user, $host, $time) = @_;
    if ($type !~ /^(get|store|show|destroy|flags)\z/) {
        $self->{error} = "invalid ACL type $type";
        return;
    }
    my $attr = "acl_$type";
    if ($acl) {
        if ($acl !~ /^\d+\z/) {
            $self->{error} = "malformed ACL id $acl";
            return;
        }
        return $self->_set_internal ($attr, $acl, $user, $host, $time);
    } else {
        return $self->_get_internal ($attr);
    }
}

# Get or set the expires value of an object.  Expects an expiration time in
# seconds since epoch.  If setting the expiration, trace information must also
# be provided.
sub expires {
    my ($self, $expires, $user, $host, $time) = @_;
    if ($expires) {
        if ($expires !~ /^\d+\z/ || $expires == 0) {
            $self->{error} = "malformed expiration time $expires";
            return;
        }
        return $self->_set_internal ('expires', $expires, $user, $host, $time);
    } else {
        return $self->_get_internal ('expires');
    }
}

##############################################################################
# Object manipulation
##############################################################################

# The get methods must always be overridden by the subclass.
sub get { die "Do not instantiate Wallet::Object directly\n"; }

# Provide a default store implementation that returns an immutable object
# error so that auto-generated types don't have to provide their own.
sub store {
    my ($self, $data, $user, $host, $time) = @_;
    my $id = $self->{type} . ':' . $self->{name};
    $self->{error} = "cannot store $id: object type is immutable";
    return;
}

# The default show function.  This may be adequate for many types; types that
# have additional data should call this method, grab the results, and then add
# their data on to the end.
sub show {
    my ($self) = @_;
    my @attrs = ([ ob_type            => 'Type'            ],
                 [ ob_name            => 'Name'            ],
                 [ ob_owner           => 'Owner'           ],
                 [ ob_acl_get         => 'Get ACL'         ],
                 [ ob_acl_store       => 'Store ACL'       ],
                 [ ob_acl_show        => 'Show ACL'        ],
                 [ ob_acl_destroy     => 'Destroy ACL'     ],
                 [ ob_acl_flags       => 'Flags ACL'       ],
                 [ ob_expires         => 'Expires'         ],
                 [ ob_created_by      => 'Created by'      ],
                 [ ob_created_from    => 'Created from'    ],
                 [ ob_created_on      => 'Created on'      ],
                 [ ob_stored_by       => 'Stored by'       ],
                 [ ob_stored_from     => 'Stored from'     ],
                 [ ob_stored_on       => 'Stored on'       ],
                 [ ob_downloaded_by   => 'Downloaded by'   ],
                 [ ob_downloaded_from => 'Downloaded from' ],
                 [ ob_downloaded_on   => 'Downloaded on'   ]);
    my $fields = join (', ', map { $_->[0] } @attrs);
    my @data;
    eval {
        my $sql = "select $fields from objects where ob_name = ? and
            ob_type = ?";
        @data = $self->{dbh}->selectrow_array ($sql, undef, $name, $type);
    };
    if ($@) {
        my $id = $self->{type} . ':' . $self->{name};
        $self->{error} = "cannot retrieve data for $id: $@";
        return undef;
    }
    my $output = '';
    for (my $i = 0; $i < @data; $i++) {
        next unless defined $data[$i];
        $output .= sprintf ("%15s: %s\n", $attrs[$i][1], $data[$i]);
    }
    return $output;
}

# The default destroy function only destroys the database metadata.  Generally
# subclasses need to override this to destroy whatever additional information
# is stored about this object.
sub destroy {
    my ($self, $user, $host, $time) = @_;
    $time ||= time;
    my $name = $self->{name};
    my $type = $self->{type};
    eval {
        my $sql = 'delete from flags where fl_object = ? and fl_type = ?';
        $self->{dbh}->do ($sql, undef, $name, $type);
        $sql = 'delete from objects where ob_name = ? and ob_type = ?';
        $self->{dbh}->do ($sql, undef, $name, $type);
        my $sql = "insert into object_history (oh_object, oh_type, oh_action,
            oh_by, oh_from, oh_on) values (?, ?, 'destroy', ?, ?, ?)";
        $self->{dbh}->do ($sql, undef, $name, $type, $user, $host, $time);
        $self->{dbh}->commit;
    };
    if ($@) {
        my $id = $self->{type} . ':' . $self->{name};
        $self->{error} = "cannot destroy $id: $@";
        $self->{dbh}->rollback;
        return undef;
    }
    return 1;
}

1;
__END__

##############################################################################
# Documentation
##############################################################################

=head1 NAME

Wallet::Object - Generic parent class for wallet objects

=head1 SYNOPSIS

    package Wallet::Object::Simple;
    @ISA = qw(Wallet::Object);
    sub get {
        my ($self, $user, $host, $time) = @_;
        $self->log_action ('get', $user, $host, $time) or return undef;
        return "Some secure data";
    }

=head1 DESCRIPTION

Wallet::Object is the generic parent class for wallet objects (data types
that can be stored in the wallet system).  It provides defualt functions and
behavior, including handling generic object settings.  All handlers for
objects stored in the wallet should inherit from it.  It is not used
directly.

=head1 PUBLIC CLASS METHODS

The following methods are called by the rest of the wallet system and should
be implemented by all objects stored in the wallet.  They should be called
with the desired wallet object class as the first argument (generally using
the Wallet::Object::Type->new syntax).

=over 4

=item new(NAME, TYPE, DBH)

Creates a new object with the given object name and type, based on data
already in the database.  This method will only succeed if an object of the
given NAME and TYPE is already present in the wallet database.  If no such
object exits, returns undef.  Otherwise, returns an object blessed into the
class used for the new() call (so subclasses can leave this method alone and
not override it).

Takes a database handle, which is stored in the object and used for any
further operations.  This database handle is taken over by the wallet system
and its settings (such as RaiseError and AutoCommit) will be modified by the
object for its own needs.

=item create(NAME, TYPE, DBH, PRINCIPAL, HOSTNAME [, DATETIME])

Similar to new() but instead creates a new entry in the database.  This
method will fail (returning undef) if an entry for that name and type
already exists in the database or if creating the database record fails.
Otherwise, a new database entry will be created with that name and type, no
owner, no ACLs, no expiration, no flags, and with created by, from, and on
set to the PRINCIPAL, HOSTNAME, and DATETIME parameters.  If DATETIME isn't
given, the current time is used.  The database handle is treated as with
new().

=back

=head1 PUBLIC INSTANCE METHODS

The following methods may be called on instantiated wallet objects.
Normally, the only methods that a subclass will need to override are get(),
store(), show(), and destroy().

=over 4

=item acl(TYPE [, ACL, PRINCIPAL, HOSTNAME [, DATETIME]])

Sets or retrieves a given object ACL as a numeric ACL ID.  TYPE must be one
of C<get>, C<store>, C<show>, C<destroy>, or C<flags>, corresponding to the
ACLs kept on an object.  If no other arguments are given, returns the
current ACL setting as an ACL ID or undef if that ACL isn't set.  If other
arguments are given, change that ACL to ACL.  The other arguments are used
for logging and history and should indicate the user and host from which the
change is made and the time of the change.

=item destroy(PRINCIPAL, HOSTNAME [, DATETIME])

Destroys the object by removing all record of it from the database.  The
Wallet::Object implementation handles the generic database work, but any
subclass should override this method to do any deletion of files or entries
in external databases and any other database entries and then call the
parent method to handle the generic database cleanup.  Returns true on
success and false on failure.  The arguments are used for logging and
history and should indicate the user and host from which the change is made
and the time of the change.

=item error()

Returns the error message from the last failing operation or undef if no
operations have failed.  Callers should call this function to get the error
message after an undef return from any other instance method.

=item expires([EXPIRES, PRINCIPAL, HOSTNAME [, DATETIME]])

Sets or retrieves the expiration date of an object.  If no arguments are
given, returns the current expiration or undef if no expiration is set.  If
arguments are given, change the expiration to EXPIRES, which should be in
seconds since epoch.  The other arguments are used for logging and history
and should indicate the user and host from which the change is made and the
time of the change.

=item get(PRINCIPAL, HOSTNAME [, DATETIME])

An object implementation must override this method with one that returns
either the data of the object or undef on some error, using the provided
arguments to update history information.  The Wallet::Object implementation
just throws an exception.

=item owner([OWNER, PRINCIPAL, HOSTNAME [, DATETIME]])

Sets or retrieves the owner of an object as a numeric ACL ID.  If no
arguments are given, returns the current owner ACL ID or undef if none is
set.  If arguments are given, change the owner to OWNER.  The other
arguments are used for logging and history and should indicate the user and
host from which the change is made and the time of the change.

=item show()

Returns a formatted text description of the object suitable for human
display, or undef on error.  The default implementation shows all of the
base metadata about the object, formatted as key: value pairs with the keys
aligned in the first 15 characters followed by a space, a colon, and the
value.  Object implementations with additional data to display can rely on
that format to add additional settings into the formatted output or at the
end with a matching format.

=item store(DATA, PRINCIPAL, HOSTNAME [, DATETIME])

Store user-supplied data into the given object.  This may not be supported
by all backends (for instance, backends that automatically generate the data
will not support this).  The default implementation rejects all store()
calls with an error message saying that the object is immutable.

=back

=head1 UTILITY METHODS

The following instance methods should not be called externally but are
provided for subclasses to call to implement some generic actions.

=over 4

=item log_action (ACTION, PRINCIPAL, HOSTNAME, DATETIME)

Updates the history tables and trace information appropriately for ACTION,
which should be either C<get> or C<store>.  No other changes are made to the
database, just updates of the history table and trace fields with the
provided data about who performed the action and when.

This function commits its transaction when complete and therefore should not
be called inside another transaction.  Normally it's called as a separate
transaction after the data is successfully stored or retrieved.

=item log_set (FIELD, OLD, NEW, PRINCIPAL, HOSTNAME, DATETIME)

Updates the history tables for the change in a setting value for an object.
FIELD should be one of C<owner>, C<acl_get>, C<acl_store>, C<acl_show>,
C<acl_destroy>, C<acl_flags>, C<expires>, C<flags>, or a value starting with
C<type_data> followed by a space and a type-specific field name.  The last
form is the most common form used by a subclass.  OLD is the previous value
of the field or undef if the field was unset, and NEW is the new value of
the field or undef if the field should be unset.

This function does not commit and does not catch database exceptions.  It
should normally be called as part of a larger transaction that implements
the change in the setting.

=back

=head1 SEE ALSO

walletd(8)

This module is part of the wallet system.  The current version is available
from L<http://www.eyrie.org/~eagle/software/wallet/>.

=head1 AUTHOR

Russ Allbery <rra@stanford.edu>

=cut
