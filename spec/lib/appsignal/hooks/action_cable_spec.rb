describe Appsignal::Hooks::ActionCableHook do
  if DependencyHelper.action_cable_present?
    context "with ActionCable" do
      require "action_cable/engine"

      describe ".dependencies_present?" do
        subject { described_class.new.dependencies_present? }

        it "returns true" do
          is_expected.to be_truthy
        end
      end

      describe ActionCable::Channel::Base do
        let(:transaction) do
          Appsignal::Transaction.new(
            transaction_id,
            Appsignal::Transaction::ACTION_CABLE,
            ActionDispatch::Request.new(env)
          )
        end
        let(:channel) do
          Class.new(ActionCable::Channel::Base) do
            def speak(_data)
            end

            def self.to_s
              "MyChannel"
            end
          end
        end
        let(:log) { StringIO.new }
        let(:server) do
          ActionCable::Server::Base.new.tap do |s|
            s.config.logger = ActiveSupport::Logger.new(log)
          end
        end
        let(:connection) { ActionCable::Connection::Base.new(server, env) }
        let(:identifier) { { :channel => "MyChannel" }.to_json }
        let(:params) { {} }
        let(:request_id) { SecureRandom.uuid }
        let(:transaction_id) { request_id }
        let(:env) do
          http_request_env_with_data("action_dispatch.request_id" => request_id, :params => params)
        end
        let(:instance) { channel.new(connection, identifier, params) }
        subject { transaction.to_h }
        before do
          start_agent
          expect(Appsignal.active?).to be_truthy
          transaction

          expect(Appsignal::Transaction).to receive(:create)
            .with(transaction_id, Appsignal::Transaction::ACTION_CABLE, kind_of(ActionDispatch::Request))
            .and_return(transaction)
          allow(Appsignal::Transaction).to receive(:current).and_return(transaction)
          # Make sure sample data is added
          expect(transaction.ext).to receive(:finish).and_return(true)
          # Stub complete call, stops it from being cleared in the extension
          # And allows us to call `#to_h` on it after it's been completed.
          expect(transaction.ext).to receive(:complete)

          # Stub transmit call for subscribe/unsubscribe tests
          allow(connection).to receive(:websocket)
            .and_return(instance_double("ActionCable::Connection::WebSocket", :transmit => nil))
        end

        describe "#perform_action" do
          it "creates a transaction for an action" do
            instance.perform_action("message" => "foo", "action" => "speak")

            expect(subject).to include(
              "action" => "MyChannel#speak",
              "error" => nil,
              "id" => transaction_id,
              "namespace" => Appsignal::Transaction::ACTION_CABLE,
              "metadata" => {
                "method" => "websocket",
                "path" => "/blog"
              }
            )
            expect(subject["events"].first).to include(
              "allocation_count" => kind_of(Integer),
              "body" => "",
              "body_format" => Appsignal::EventFormatter::DEFAULT,
              "child_allocation_count" => kind_of(Integer),
              "child_duration" => kind_of(Float),
              "child_gc_duration" => kind_of(Float),
              "count" => 1,
              "gc_duration" => kind_of(Float),
              "start" => kind_of(Float),
              "duration" => kind_of(Float),
              "name" => "perform_action.action_cable",
              "title" => ""
            )
            expect(subject["sample_data"]).to include(
              "params" => {
                "action" => "speak",
                "message" => "foo"
              }
            )
          end

          context "without request_id (standalone server)" do
            let(:request_id) { nil }
            let(:transaction_id) { SecureRandom.uuid }
            let(:action_transaction) do
              Appsignal::Transaction.new(
                transaction_id,
                Appsignal::Transaction::ACTION_CABLE,
                ActionDispatch::Request.new(env)
              )
            end
            before do
              # Stub future (private AppSignal) transaction id generated by the hook.
              expect(SecureRandom).to receive(:uuid).and_return(transaction_id)
            end

            it "uses its own internal request_id set by the subscribed callback" do
              # Subscribe action, sets the request_id
              instance.subscribe_to_channel
              expect(transaction.to_h["id"]).to eq(transaction_id)

              # Expect another transaction for the action.
              # This transaction will use the same request_id as the
              # transaction id used to subscribe to the channel.
              expect(Appsignal::Transaction).to receive(:create).with(
                transaction_id,
                Appsignal::Transaction::ACTION_CABLE,
                kind_of(ActionDispatch::Request)
              ).and_return(action_transaction)
              allow(Appsignal::Transaction).to receive(:current).and_return(action_transaction)
              # Stub complete call, stops it from being cleared in the extension
              # And allows us to call `#to_h` on it after it's been completed.
              expect(action_transaction.ext).to receive(:complete)

              instance.perform_action("message" => "foo", "action" => "speak")
              expect(action_transaction.to_h["id"]).to eq(transaction_id)
            end
          end

          context "with an error in the action" do
            let(:channel) do
              Class.new(ActionCable::Channel::Base) do
                def speak(_data)
                  raise VerySpecificError, "oh no!"
                end

                def self.to_s
                  "MyChannel"
                end
              end
            end

            it "registers an error on the transaction" do
              expect do
                instance.perform_action("message" => "foo", "action" => "speak")
              end.to raise_error(VerySpecificError)

              expect(subject).to include(
                "action" => "MyChannel#speak",
                "id" => transaction_id,
                "namespace" => Appsignal::Transaction::ACTION_CABLE,
                "metadata" => {
                  "method" => "websocket",
                  "path" => "/blog"
                }
              )
              expect(subject["error"]).to include(
                "backtrace" => kind_of(String),
                "name" => "VerySpecificError",
                "message" => "oh no!"
              )
              expect(subject["sample_data"]).to include(
                "params" => {
                  "action" => "speak",
                  "message" => "foo"
                }
              )
            end
          end
        end

        describe "subscribe callback" do
          let(:params) { { "internal" => true } }

          it "creates a transaction for a subscription" do
            instance.subscribe_to_channel

            expect(subject).to include(
              "action" => "MyChannel#subscribed",
              "error" => nil,
              "id" => transaction_id,
              "namespace" => Appsignal::Transaction::ACTION_CABLE,
              "metadata" => {
                "method" => "websocket",
                "path" => "/blog"
              }
            )
            expect(subject["events"].first).to include(
              "allocation_count" => kind_of(Integer),
              "body" => "",
              "body_format" => Appsignal::EventFormatter::DEFAULT,
              "child_allocation_count" => kind_of(Integer),
              "child_duration" => kind_of(Float),
              "child_gc_duration" => kind_of(Float),
              "count" => 1,
              "gc_duration" => kind_of(Float),
              "start" => kind_of(Float),
              "duration" => kind_of(Float),
              "name" => "subscribed.action_cable",
              "title" => ""
            )
            expect(subject["sample_data"]).to include(
              "params" => { "internal" => "true" }
            )
          end

          context "without request_id (standalone server)" do
            let(:request_id) { nil }
            let(:transaction_id) { SecureRandom.uuid }
            before do
              allow(SecureRandom).to receive(:uuid).and_return(transaction_id)
              instance.subscribe_to_channel
            end

            it "uses its own internal request_id" do
              expect(subject["id"]).to eq(transaction_id)
            end
          end

          context "with an error in the callback" do
            let(:channel) do
              Class.new(ActionCable::Channel::Base) do
                def subscribed
                  raise VerySpecificError, "oh no!"
                end

                def self.to_s
                  "MyChannel"
                end
              end
            end

            it "registers an error on the transaction" do
              expect do
                instance.subscribe_to_channel
              end.to raise_error(VerySpecificError)

              expect(subject).to include(
                "action" => "MyChannel#subscribed",
                "id" => transaction_id,
                "namespace" => Appsignal::Transaction::ACTION_CABLE,
                "metadata" => {
                  "method" => "websocket",
                  "path" => "/blog"
                }
              )
              expect(subject["error"]).to include(
                "backtrace" => kind_of(String),
                "name" => "VerySpecificError",
                "message" => "oh no!"
              )
              expect(subject["sample_data"]).to include(
                "params" => { "internal" => "true" }
              )
            end
          end
        end

        describe "unsubscribe callback" do
          let(:params) { { "internal" => true } }

          it "creates a transaction for a subscription" do
            instance.unsubscribe_from_channel

            expect(subject).to include(
              "action" => "MyChannel#unsubscribed",
              "error" => nil,
              "id" => transaction_id,
              "namespace" => Appsignal::Transaction::ACTION_CABLE,
              "metadata" => {
                "method" => "websocket",
                "path" => "/blog"
              }
            )
            expect(subject["events"].first).to include(
              "allocation_count" => kind_of(Integer),
              "body" => "",
              "body_format" => Appsignal::EventFormatter::DEFAULT,
              "child_allocation_count" => kind_of(Integer),
              "child_duration" => kind_of(Float),
              "child_gc_duration" => kind_of(Float),
              "count" => 1,
              "gc_duration" => kind_of(Float),
              "start" => kind_of(Float),
              "duration" => kind_of(Float),
              "name" => "unsubscribed.action_cable",
              "title" => ""
            )
            expect(subject["sample_data"]).to include(
              "params" => { "internal" => "true" }
            )
          end

          context "without request_id (standalone server)" do
            let(:request_id) { nil }
            let(:transaction_id) { SecureRandom.uuid }
            before do
              allow(SecureRandom).to receive(:uuid).and_return(transaction_id)
              instance.unsubscribe_from_channel
            end

            it "uses its own internal request_id" do
              expect(subject["id"]).to eq(transaction_id)
            end
          end

          context "with an error in the callback" do
            let(:channel) do
              Class.new(ActionCable::Channel::Base) do
                def unsubscribed
                  raise VerySpecificError, "oh no!"
                end

                def self.to_s
                  "MyChannel"
                end
              end
            end

            it "registers an error on the transaction" do
              expect do
                instance.unsubscribe_from_channel
              end.to raise_error(VerySpecificError)

              expect(subject).to include(
                "action" => "MyChannel#unsubscribed",
                "id" => transaction_id,
                "namespace" => Appsignal::Transaction::ACTION_CABLE,
                "metadata" => {
                  "method" => "websocket",
                  "path" => "/blog"
                }
              )
              expect(subject["error"]).to include(
                "backtrace" => kind_of(String),
                "name" => "VerySpecificError",
                "message" => "oh no!"
              )
              expect(subject["sample_data"]).to include(
                "params" => { "internal" => "true" }
              )
            end
          end
        end
      end
    end
  else
    context "without ActionCable" do
      describe ".dependencies_present?" do
        subject { described_class.new.dependencies_present? }

        it "returns false" do
          is_expected.to be_falsy
        end
      end
    end
  end
end
