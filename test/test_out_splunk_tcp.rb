require 'test/unit'
require 'fluent/test'
require 'fluent/plugin/out_splunk_tcp'

require 'net/https'
require 'uri'
require 'json'
require 'securerandom'

class SplunkTCPOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

  def teardown
  end

  CONFIG = %[
    port 8089
    event_key event
  ]

  def create_driver(conf = CONFIG)
    Fluent::Test::BufferedOutputTestDriver.new(Fluent::SplunkTCPOutput){
      # Fluentd v0.12 BufferedOutputTestDriver calls this method.
      # BufferedOutput#format_stream calls format method, but ForwardOutput#format is not defined.
      # Because ObjectBufferedOutput#emit calls es.to_msgpack_stream directly.
      def format_stream(tag, es)
        es.to_msgpack_stream
      end
    }.configure(conf)
  end

  ## query(port, 'source="SourceName"')
  def get_events(port, search_query, expected_num = 1)
    retries = 0
    events = []
    while events.length != expected_num
      print '-' unless retries == 0
      sleep(3)
      events = query(port, {'search' => 'search ' + search_query})
      retries += 1
      raise "exceed query retry limit" if retries > 20
    end
    events
  end

  def query(port, q)
    uri = URI.parse("https://127.0.0.1:#{port}/services/search/jobs/export")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    req = Net::HTTP::Post.new(uri.path)
    req.basic_auth('admin', 'changeme')
    req.set_form_data(q.merge({'output_mode' => 'json', 'time_format' => '%s'}))
    http.request(req).body.split("\n").map{|line| JSON.parse(line)}.delete_if{|json| json['lastrow']}
  end

  test 'configure' do
    d = create_driver
    assert_equal 'localhost', d.instance.host
    assert_equal 8089, d.instance.port
    assert_equal 'event', d.instance.event_key
    assert_equal false, d.instance.ssl_verify_peer
    assert_equal nil, d.instance.ca_file
    assert_equal nil, d.instance.client_cert
    assert_equal nil, d.instance.client_key
    assert_equal nil, d.instance.client_key_pass
  end

  ## I just wanna run same test code for HTTP and HTTPS...
  [{sub_test_case_name: 'TCP', query_port: 8089, server_port: 12300, config: %[
                                                                               host 127.0.0.1
                                                                               port 12300
                                                                               event_key event
                                                                               ssl_verify_peer false
                                                                             ]},
   {sub_test_case_name: 'SSL', query_port: 8289, server_port: 12500, config: %[
                                                                               host 127.0.0.1
                                                                               port 12500
                                                                               event_key event
                                                                               ssl_verify_peer true
                                                                               ca_file #{File.expand_path('../cert/cacert.pem', __FILE__)}
                                                                               client_cert #{File.expand_path('../cert/client.pem', __FILE__)}
                                                                               client_key #{File.expand_path('../cert/client.key', __FILE__)}
                                                                             ]}
  ].each do |test_config|
    sub_test_case test_config[:sub_test_case_name] do
      teardown do
        query(test_config[:query_port], {'search' => "search source=\"tcp:#{test_config[:server_port]}\" | delete"})
      end

      test 'single insert' do
        d = create_driver(test_config[:config])
        time = Time.now.to_i - 100
        event = {'time' => time, 'test' => SecureRandom.hex}
        d.emit({'event' => event.to_json}, time)
        d.run
        result = get_events(test_config[:query_port], "source=\"tcp:#{test_config[:server_port]}\"")[0]
        assert_equal(time, result['result']['_time'].to_i)
        assert_equal(event, JSON.parse(result['result']['_raw']))
      end

      test 'batched insert' do
        d = create_driver(test_config[:config])
        time0 = Time.now.to_i - 100
        event0 = {'time' => time0, 'test' => SecureRandom.hex}
        time1 = Time.now.to_i - 200
        event1 = {'time' => time1, 'test' => SecureRandom.hex}
        d.emit({'event' => event0.to_json}, time0)
        d.emit({'event' => event1.to_json}, time1)
        d.run
        events = get_events(test_config[:query_port], "source=\"tcp:#{test_config[:server_port]}\"", 2)
        assert_equal(time0, events[0]['result']['_time'].to_i)
        assert_equal(event0, JSON.parse(events[0]['result']['_raw']))
        assert_equal(time1, events[1]['result']['_time'].to_i)
        assert_equal(event1, JSON.parse(events[1]['result']['_raw']))
      end
    end
  end
end
