# frozen_string_literal: true

require 'ruby4lich5/classification'

RSpec.describe Ruby4Lich5::Classification do
  describe '#initialize' do
    it 'accepts each valid state when given the fields that state requires' do
      expect { described_class.new(state: :pure, gem_name: 'ascii_charts', gem_version: '1.0.0') }
        .not_to raise_error
      expect do
        described_class.new(
          state: :native_pass_through, gem_name: 'sqlite3', gem_version: '1.7.3',
          platform_asset: 'sqlite3-1.7.3-x64-mingw-ucrt.gem'
        )
      end.not_to raise_error
      expect do
        described_class.new(
          state: :native_self_contained, gem_name: 'gtk3', gem_version: '4.3.7',
          msys2_packages: ['mingw-w64-ucrt-x86_64-gtk3']
        )
      end.not_to raise_error
      expect do
        described_class.new(state: :native_needs_system_lib, gem_name: 'mystery-gem', gem_version: '0.1.0')
      end.not_to raise_error
    end

    it 'rejects a state outside STATES' do
      expect { described_class.new(state: :bogus, gem_name: 'sqlite3', gem_version: '1.7.3') }
        .to raise_error(ArgumentError, /state must be one of/)
    end

    context 'state-specific field invariants' do
      it 'rejects :native_pass_through without a platform_asset' do
        expect { described_class.new(state: :native_pass_through, gem_name: 'sqlite3', gem_version: '1.7.3') }
          .to raise_error(ArgumentError, /requires platform_asset/)
      end

      it 'rejects :native_self_contained without msys2_packages' do
        expect { described_class.new(state: :native_self_contained, gem_name: 'gtk3', gem_version: '4.3.7') }
          .to raise_error(ArgumentError, /requires msys2_packages/)
      end

      it 'rejects :native_self_contained with an empty msys2_packages array' do
        expect do
          described_class.new(
            state: :native_self_contained, gem_name: 'gtk3', gem_version: '4.3.7', msys2_packages: []
          )
        end.to raise_error(ArgumentError, /requires msys2_packages/)
      end

      it 'rejects :pure with a stray platform_asset' do
        expect do
          described_class.new(
            state: :pure, gem_name: 'ascii_charts', gem_version: '1.0.0', platform_asset: 'unexpected.gem'
          )
        end.to raise_error(ArgumentError, /must not set platform_asset/)
      end

      it 'rejects :pure with stray msys2_packages' do
        expect do
          described_class.new(
            state: :pure, gem_name: 'ascii_charts', gem_version: '1.0.0', msys2_packages: ['unexpected']
          )
        end.to raise_error(ArgumentError, /must not set msys2_packages/)
      end

      it 'rejects :native_needs_system_lib with a stray msys2_packages' do
        expect do
          described_class.new(
            state: :native_needs_system_lib, gem_name: 'mystery-gem', gem_version: '0.1.0',
            msys2_packages: ['unexpected']
          )
        end.to raise_error(ArgumentError, /must not set msys2_packages/)
      end

      it 'rejects :native_pass_through with stray msys2_packages' do
        expect do
          described_class.new(
            state: :native_pass_through, gem_name: 'sqlite3', gem_version: '1.7.3',
            platform_asset: 'sqlite3-1.7.3-x64-mingw-ucrt.gem', msys2_packages: ['unexpected']
          )
        end.to raise_error(ArgumentError, /must not set msys2_packages/)
      end
    end
  end

  describe '#pure?' do
    it 'is true only for the :pure state' do
      pure = described_class.new(state: :pure, gem_name: 'ascii_charts', gem_version: '1.0.0')
      native = described_class.new(
        state: :native_self_contained, gem_name: 'gtk3', gem_version: '4.3.7',
        msys2_packages: ['mingw-w64-ucrt-x86_64-gtk3']
      )

      expect(pure.pure?).to be(true)
      expect(native.pure?).to be(false)
    end
  end

  describe '#pass_through?' do
    it 'is true only for the :native_pass_through state' do
      pass_through = described_class.new(
        state: :native_pass_through, gem_name: 'sqlite3', gem_version: '1.7.3',
        platform_asset: 'sqlite3-1.7.3-x64-mingw-ucrt.gem'
      )
      other = described_class.new(state: :pure, gem_name: 'ascii_charts', gem_version: '1.0.0')

      expect(pass_through.pass_through?).to be(true)
      expect(other.pass_through?).to be(false)
    end
  end

  describe '#self_contained?' do
    it 'is true only for the :native_self_contained state' do
      self_contained = described_class.new(
        state: :native_self_contained, gem_name: 'gtk3', gem_version: '4.3.7',
        msys2_packages: ['mingw-w64-ucrt-x86_64-gtk3']
      )
      other = described_class.new(state: :pure, gem_name: 'ascii_charts', gem_version: '1.0.0')

      expect(self_contained.self_contained?).to be(true)
      expect(other.self_contained?).to be(false)
    end
  end

  describe '#needs_system_lib?' do
    it 'is true only for the :native_needs_system_lib state' do
      rejected = described_class.new(state: :native_needs_system_lib, gem_name: 'mystery-gem', gem_version: '0.1.0')
      other = described_class.new(state: :pure, gem_name: 'ascii_charts', gem_version: '1.0.0')

      expect(rejected.needs_system_lib?).to be(true)
      expect(other.needs_system_lib?).to be(false)
    end
  end
end
