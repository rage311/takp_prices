#!/usr/bin/env perl

use 5.026;

use Mojo::Base -strict, -signatures;
use Mojo::JSON qw(to_json);
use Mojo::UserAgent;
use Mojo::Util qw(dumper trim);
use Net::Pcap::Easy;


use constant DEBUG               => $ENV{DEBUG}  // 1;
use constant CAP_DEVICE          => $ENV{DEVICE} // 'enp0s25';
use constant PACKET_ENDPOINT_URL => 'http://server_endpoint_here';
use constant TAKP_IP             => '144.121.19.189';
use constant API_KEY             => 'super $3crEt API key here';

my $ua = Mojo::UserAgent->new;
my @instance_queue;

sub parse_payload ($data) {
  my ($name_qty, $price, $trader_id, $item_id) =
    unpack 'x4 A64 H8 H4 H4 x16', reverse $data;

  my $bytes_hex = join ' ', unpack '(H2)*', $data;

  return unless
    defined $name_qty
    && defined $price
    && defined $trader_id
    && defined $item_id;

  chomp($name_qty = reverse trim $name_qty);
  my ($item_name, $quantity) = ($name_qty =~ /^(.+) \((\d+)\)/);
  return unless defined $item_name && defined $quantity;

  my $price_cp = hex($price);
  my $price_pp = int($price_cp / 1000);
  $trader_id   = hex($trader_id);
  $item_id     = hex($item_id);

  if (DEBUG()) {
    say $bytes_hex;
    say $item_name;
    say 'Quantity  : ', $quantity;
    say 'Price     : ', $price_pp, 'pp';
    say 'Trader ID : ', $trader_id;
    say 'Item ID   : ', $item_id;
    say '';
  }

  return {
    item_id   => $item_id,
    item_name => $item_name,
    quantity  => $quantity,
    trader_id => $trader_id,
    price_cp  => $price_cp,
    price_pp  => $price_pp,
    bytes     => $bytes_hex,
  };
}

sub handle_udp ($npe, $ether, $ip, $udp, $header) {
  return unless $udp->{len} == 100;

  my $instance = parse_payload($udp->{data});
  warn 'Parsing failed' and return unless $instance;

  push @instance_queue, $instance;
}

my $npe = Net::Pcap::Easy->new(
  dev              => CAP_DEVICE(),
  filter           => 'host ' . TAKP_IP() . ' and udp and greater 134 and less 135',
  packets_per_loop => 4,
  bytes_to_capture => 1024,
  promiscuous      => 0,
  udp_callback     => \&handle_udp,
);

while ($npe->loop) {
  next unless @instance_queue;

  my $res = $ua->post(PACKET_ENDPOINT_URL() =>
    form => {
      payload => to_json(\@instance_queue),
      api_key => API_KEY,
    })->result;

  say dumper $res unless $res->code == 200;

  @instance_queue = ();
}

