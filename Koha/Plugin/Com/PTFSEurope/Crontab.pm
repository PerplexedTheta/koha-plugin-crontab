use utf8;

package Koha::Plugin::Com::PTFSEurope::Crontab;

use Modern::Perl;
use base qw(Koha::Plugins::Base);

use Module::Metadata;
use Config::Crontab;

#BEGIN {
#    my $path = Module::Metadata->find_module_by_name(__PACKAGE__);
#    $path =~ s!\.pm$!/lib!;
#    unshift @INC, $path;
#
#    use Crontab::API;
#}

our $VERSION  = "{VERSION}";
our $metadata = {
    name            => 'Crontab',
    author          => 'Martin Renvoize',
    description     => 'Add instance crontab management to Koha',
    date_authored   => '2023-04-25',
    date_updated    => "1970-01-01",
    minimum_version => '22.1100000',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'crontab.tt' } );

    my $ct = new Config::Crontab;
    $ct->mode('block');
    $ct->read or do {
        $template->param( error => $ct->error );
        $self->output_html( $template->output() );
        return;
    };

    my $block_no = 0;
    my $blocks = [];
    for my $block ( $ct->blocks ) {
        $block_no++;

        my @comments = $block->select( -type => 'comment' );
        my @env      = $block->select( -type => 'env' );
        my @events   = $block->select( -type => 'event' );

        push @{$blocks}, { no => $block_no,  comments => \@comments, environment => \@env, events => \@events };
    }
    $template->param( blocks => $blocks );
    $self->output_html( $template->output() );
}

1;
