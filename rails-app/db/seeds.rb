%w[apple banana cherry].each_with_index do |name, i|
  Item.find_or_create_by!(name: name) { |item| item.quantity = (i + 1) * 10 }
end
