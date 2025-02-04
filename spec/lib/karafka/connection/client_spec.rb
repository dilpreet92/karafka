# frozen_string_literal: true

RSpec.describe Karafka::Connection::Client do
  subject(:client) { described_class.new(consumer_group) }

  let(:group) { rand.to_s }
  let(:topic) { rand.to_s }
  let(:partition) { rand(100) }
  let(:batch_fetching) { false }
  let(:start_from_beginning) { false }
  let(:kafka_consumer) { instance_double(Kafka::Consumer, stop: true, pause: true) }
  let(:consumer_group) do
    batch_fetching_active = batch_fetching
    start_from_beginning_active = start_from_beginning
    Karafka::Routing::ConsumerGroup.new(group).tap do |cg|
      cg.batch_fetching = batch_fetching_active

      cg.public_send(:topic=, topic) do
        consumer Class.new(Karafka::BaseConsumer)
        backend :inline
        start_from_beginning start_from_beginning_active
      end
    end
  end

  before do
    Karafka::Server.consumer_groups = [group]
  end

  describe '.new' do
    it 'just remembers consumer_group' do
      expect(client.instance_variable_get(:@consumer_group)).to eq consumer_group
    end
  end

  describe '#stop' do
    before { client.instance_variable_set(:'@kafka_consumer', kafka_consumer) }

    it 'expect to stop consumer' do
      expect(kafka_consumer)
        .to receive(:stop)

      client.stop
    end

    it 'expect to remove kafka_consumer' do
      client.instance_variable_set(:'@kafka_consumer', kafka_consumer)
      client.stop
      expect(client.instance_variable_get(:'@kafka_consumer')).to eq nil
    end
  end

  describe '#pause' do
    let(:pause_timeout) { rand }
    let(:pause_max_timeout) { rand }
    let(:pause_exponential_backoff) { false }
    let(:pause_args) { [topic, partition] }
    let(:pause_kwargs) do
      {
        timeout: pause_timeout,
        max_timeout: pause_max_timeout,
        exponential_backoff: pause_exponential_backoff
      }
    end

    before do
      client.instance_variable_set(:'@kafka_consumer', kafka_consumer)
      allow(consumer_group)
        .to receive(:pause_timeout)
        .and_return(pause_timeout)
      allow(consumer_group)
        .to receive(:pause_max_timeout)
        .and_return(pause_max_timeout)
      allow(consumer_group)
        .to receive(:pause_exponential_backoff)
        .and_return(pause_exponential_backoff)
    end

    context 'when pause_timeout is set to nil' do
      let(:error) { Karafka::Errors::InvalidPauseTimeout }

      it 'expect to raise an exception' do
        expect(kafka_consumer).to receive(:pause).with(*pause_args, **pause_kwargs)
        expect(client.pause(topic, partition)).to eq true
      end
    end

    context 'when pause_timeout is set to 0' do
      let(:pause_timeout) { 0 }
      let(:error) { Karafka::Errors::InvalidPauseTimeout }

      it 'expect to raise an exception' do
        expect(kafka_consumer).to receive(:pause).with(*pause_args, **pause_kwargs)
        expect(client.pause(topic, partition)).to eq true
      end
    end

    context 'when pause_timeout is not set to 0' do
      let(:pause_timeout) { rand(1..100) }

      it 'expect to pause consumer_group' do
        expect(kafka_consumer).to receive(:pause).with(*pause_args, **pause_kwargs)
        expect(client.pause(topic, partition)).to eq true
      end
    end

    context 'when pausing with a non-default morphing topic mapper' do
      let(:pause_timeout) { rand(1..100) }
      let(:r_topic) { custom_mapper.outgoing(topic) }
      let(:custom_mapper) do
        klass = ClassBuilder.build do
          def outgoing(topic)
            "remapped-#{topic}"
          end
        end

        klass.new
      end
      let(:pause_args) { [r_topic, partition] }

      before do
        allow(Karafka::App.config).to receive(:topic_mapper).and_return(custom_mapper)
      end

      it 'expect to pause consumer_group for a remapped topic' do
        expect(kafka_consumer).to receive(:pause).with(*pause_args, **pause_kwargs)
        expect(client.pause(topic, partition)).to eq true
      end
    end
  end

  describe '#mark_as_consumed' do
    let(:params) { instance_double(Karafka::Params::Params, metadata: metadata) }
    let(:metadata) { instance_double(Karafka::Params::Metadata) }

    before { client.instance_variable_set(:'@kafka_consumer', kafka_consumer) }

    it 'expect to forward to mark_message_as_processed and not to commit offsets' do
      expect(kafka_consumer).to receive(:mark_message_as_processed).with(metadata)
      expect(kafka_consumer).not_to receive(:commit_offsets)
      client.mark_as_consumed(params)
    end
  end

  describe '#mark_as_consumed!' do
    let(:params) { instance_double(Karafka::Params::Params, metadata: metadata) }
    let(:metadata) { instance_double(Karafka::Params::Metadata) }

    before { client.instance_variable_set(:'@kafka_consumer', kafka_consumer) }

    it 'expect to forward to mark_message_as_processed and commit offsets' do
      expect(kafka_consumer).to receive(:mark_message_as_processed).with(metadata)
      expect(kafka_consumer).to receive(:commit_offsets)
      client.mark_as_consumed!(params)
    end
  end

  describe '#trigger_heartbeat' do
    before { client.instance_variable_set(:'@kafka_consumer', kafka_consumer) }

    it 'expect to use the consumers non blocking trigger_heartbeat method' do
      expect(kafka_consumer).to receive(:trigger_heartbeat)
      client.trigger_heartbeat
    end
  end

  describe '#trigger_heartbeat!' do
    before { client.instance_variable_set(:'@kafka_consumer', kafka_consumer) }

    it 'expect to use the consumers blocking trigger_heartbeat! method' do
      expect(kafka_consumer).to receive(:trigger_heartbeat!)
      client.trigger_heartbeat!
    end
  end

  describe '#fetch_loop' do
    let(:incoming_message) { rand }

    before { client.instance_variable_set(:'@kafka_consumer', kafka_consumer) }

    context 'when everything works smooth' do
      context 'with single message consumption mode' do
        it 'expect to use kafka_consumer to get each message and yield as an array of messages' do
          expect(kafka_consumer).to receive(:each_message).and_yield(incoming_message)
          expect { |block| client.fetch_loop(&block) }
            .to yield_with_args(incoming_message, :message)
        end
      end

      context 'with message batch consumption mode' do
        let(:batch_fetching) { true }
        let(:incoming_batch) { build(:kafka_fetched_batch) }

        it 'expect to use kafka_consumer to get messages and yield all of them' do
          expect(kafka_consumer).to receive(:each_batch).and_yield(incoming_batch)
          expect { |block| client.fetch_loop(&block) }
            .to yield_successive_args([incoming_batch, :batch])
        end
      end
    end

    context 'when Kafka::ProcessingError occurs' do
      let(:error) do
        Kafka::ProcessingError.new(
          topic,
          partition,
          cause: StandardError.new
        )
      end

      before do
        count = 0
        allow(kafka_consumer).to receive(:each_message).twice do
          count += 1
          count == 1 ? raise(error) : true
        end

        # Lets silence exceptions printing
        allow(Karafka.monitor)
          .to receive(:notice_error)
          .with(described_class, error.cause)
      end

      it 'notice, pause and not reraise error' do
        expect(kafka_consumer).to receive(:pause).and_return(true)
        expect { client.fetch_loop {} }.not_to raise_error
      end
    end

    context 'when no consuming error' do
      let(:error) { Exception.new }

      before do
        count = 0
        allow(kafka_consumer).to receive(:each_message).twice do
          count += 1
          count == 1 ? raise(error) : true
        end

        # Lets silence exceptions printing
        allow(Karafka.monitor)
          .to receive(:notice_error)
          .with(described_class, error)
      end

      it 'notices and reraises error' do
        expect(kafka_consumer).not_to receive(:pause)
        expect { client.fetch_loop {} }.to raise_error(error)
      end
    end
  end

  describe '#kafka_consumer' do
    context 'when kafka_consumer is already built' do
      before { client.instance_variable_set(:'@kafka_consumer', kafka_consumer) }

      it 'expect to return it' do
        expect(client.send(:kafka_consumer)).to eq kafka_consumer
      end
    end

    context 'when kafka_consumer is not yet built' do
      let(:kafka_client) { instance_double(Kafka::Client) }
      let(:kafka_consumer) { instance_double(Kafka::Consumer) }
      let(:subscribe_params) do
        [
          consumer_group.topics.first.name,
          {
            start_from_beginning: start_from_beginning,
            max_bytes_per_partition: 1_048_576
          }
        ]
      end

      before { allow(Karafka::Connection::Builder).to receive(:call).and_return(kafka_client) }

      it 'expect to build it and subscribe' do
        expect(kafka_client).to receive(:consumer).and_return(kafka_consumer)
        expect(kafka_consumer).to receive(:subscribe).with(*subscribe_params)
        expect(client.send(:kafka_consumer)).to eq kafka_consumer
      end
    end

    context 'when there was a kafka connection failure' do
      before do
        client.instance_variable_set(:'@kafka_consumer', nil)
        allow(Kafka).to receive(:new).and_raise(Kafka::ConnectionError)
      end

      it 'expect to sleep and reraise' do
        expect(client).to receive(:sleep).with(5)

        expect { client.send(:kafka_consumer) }.to raise_error(Kafka::ConnectionError)
      end
    end
  end
end
