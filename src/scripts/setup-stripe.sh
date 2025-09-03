#!/bin/bash

# Simple script to create a Stripe product and price
# Run this after setting up your Stripe account

echo "Setting up Stripe product and price..."

# Create product
PRODUCT_RESPONSE=$(curl -X POST https://api.stripe.com/v1/products \
  -u "$STRIPE_SECRET_KEY:" \
  -d "name=Shop Manager Basic Plan" \
  -d "description=Monthly subscription for Shop Manager" \
  -d "type=service")

PRODUCT_ID=$(echo $PRODUCT_RESPONSE | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
echo "Created product: $PRODUCT_ID"

# Create price
PRICE_RESPONSE=$(curl -X POST https://api.stripe.com/v1/prices \
  -u "$STRIPE_SECRET_KEY:" \
  -d "product=$PRODUCT_ID" \
  -d "unit_amount=1000" \
  -d "currency=usd" \
  -d "recurring[interval]=month")

PRICE_ID=$(echo $PRICE_RESPONSE | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
echo "Created price: $PRICE_ID"

echo ""
echo "Add this to your .env file:"
echo "VITE_STRIPE_PRICE_ID=$PRICE_ID"
