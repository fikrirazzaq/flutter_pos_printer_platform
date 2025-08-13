// Examples of mixed Latin and Chinese text printing

class MixedTextExamples {
  // Example 1: Restaurant receipt with mixed languages
  static String generateRestaurantReceipt() {
    return """
Welcome to 北京餐厅 Beijing Restaurant
欢迎光临！Welcome!

Order #12345 订单号码: 12345
Date: 2024-01-15 日期: 2024年1月15日

MENU 菜单:
1. Kung Pao Chicken 宫保鸡丁    \$12.99
2. Sweet and Sour Pork 糖醋里脊  \$11.50
3. Fried Rice 炒饭               \$8.99
4. Hot Tea 热茶                  \$2.50

Subtotal 小计:                   \$35.98
Tax 税费:                        \$2.88
Total 总计:                      \$38.86

Thank you! 谢谢光临!
再次光临 Come again!
""";
  }

  // Example 2: Product label with specifications
  static String generateProductLabel() {
    return """
Product Name 产品名称:
iPhone 15 Pro Max 苹果手机

Model 型号: A2849
Storage 存储: 512GB
Color 颜色: Natural Titanium 原色钛金属

Price 价格: \$1,199.00 / ¥8,699.00
SKU: IPH15PM512NT

Made in China 中国制造
Apple Inc. 苹果公司
""";
  }

  // Example 3: Multilingual address
  static String generateAddress() {
    return """
Delivery Address 配送地址:

John Smith 约翰·史密斯
123 Main Street 主街123号
Apartment 5B 5B公寓
New York, NY 10001 纽约
United States 美国

Phone 电话: +1-555-123-4567
Email 邮箱: john@email.com
""";
  }

  // Example 4: Simple mixed sentences
  static List<String> getSimpleExamples() {
    return [
      "Hello 你好 World 世界!",
      "Price 价格: \$25.99 / ¥189.00",
      "Welcome 欢迎! Order #123 订单号: 123",
      "Store Name 店铺名称: Tech Store 科技商店",
      "Thank you 谢谢! Come again 再次光临!",
    ];
  }
}
