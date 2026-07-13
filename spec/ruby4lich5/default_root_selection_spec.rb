# frozen_string_literal: true

require 'ruby4lich5/default_root_selection'

RSpec.describe Ruby4Lich5::DefaultRootSelection do
  describe '.resolve_versions' do
    it "resolves gtk3 to the fixed GTK3_VERSION, never a RubygemsClient lookup" do
      rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
      allow(rubygems_client).to receive(:latest_version).with(any_args) { |name| "#{name}-latest" }

      result = described_class.resolve_versions(rubygems_client: rubygems_client)

      expect(result['gtk3']).to eq(described_class::GTK3_VERSION)
      expect(rubygems_client).not_to have_received(:latest_version).with('gtk3')
    end

    it 'resolves every RUNTIME_GEMS root via RubygemsClient#latest_version' do
      rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
      allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

      result = described_class.resolve_versions(rubygems_client: rubygems_client)

      described_class::RUNTIME_GEMS.each do |name|
        expect(result[name]).to eq("#{name}-resolved")
        expect(rubygems_client).to have_received(:latest_version).with(name)
      end
    end

    it 'never includes cairo as an independent root -- the actual fix for the cairo-version/closure mismatch gap' do
      rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
      allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

      result = described_class.resolve_versions(rubygems_client: rubygems_client)

      expect(result).not_to have_key('cairo')
      # Not just "the result has no cairo key" -- the stub above answers
      # any name, so a stray #latest_version('cairo') call whose result
      # was simply never stored would still pass the key check alone.
      # This confirms the interaction itself never happens.
      expect(rubygems_client).not_to have_received(:latest_version).with('cairo')
    end

    it 'returns exactly gtk3 plus RUNTIME_GEMS, no more, no fewer' do
      rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
      allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

      result = described_class.resolve_versions(rubygems_client: rubygems_client)

      expect(result.keys).to contain_exactly('gtk3', *described_class::RUNTIME_GEMS)
    end
  end
end
